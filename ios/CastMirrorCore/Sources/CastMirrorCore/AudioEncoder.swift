import AVFoundation
import CoreMedia
import Foundation

/// Turns app audio into one continuous AAC-LC stream at 48 kHz stereo.
/// Silences (no app playing sound) are filled in, because the receiver can
/// only play as far as both the audio and the video reach.
final class AudioEncoder {
    static let sampleRate = 48_000
    static let channels = 2
    static let samplesPerPacket = 1024
    /// Apple's AAC encoder delays its output by this many samples (TN2258).
    static let primingSamples = 2112

    struct Packets {
        /// Number of the first packet; packet n starts at sample n * 1024.
        let first: Int64
        let data: [Data]
    }

    var config: AudioTrackConfig { AudioTrackConfig(sampleRate: Self.sampleRate, channels: Self.channels) }

    /// Next sample position (48 kHz, from the stream's start) to be encoded.
    private(set) var nextSample: Int64 = 0

    private let pcmFormat: AVAudioFormat
    private let encoder: AVAudioConverter
    private var resampler: AVAudioConverter?
    private var encoderInput: [AVAudioPCMBuffer] = []
    private var packets: [Data] = []
    private var packetsTaken: Int64 = 0

    init?() {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: Double(Self.sampleRate), channels: AVAudioChannelCount(Self.channels)) else {
            return nil
        }
        var aac = AudioStreamBasicDescription(
            mSampleRate: Double(Self.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.samplesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(Self.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let aacFormat = AVAudioFormat(streamDescription: &aac), let encoder = AVAudioConverter(from: pcm, to: aacFormat) else {
            return nil
        }
        encoder.bitRate = 128_000
        pcmFormat = pcm
        self.encoder = encoder
    }

    /// Adds app audio that starts at `startSample` (48 kHz, from the stream's
    /// start), in any PCM format.
    func append(_ buffer: AVAudioPCMBuffer, startSample: Int64) {
        guard let pcm = resample(buffer), pcm.frameLength > 0 else { return }
        let drift = startSample - nextSample
        let slack = Int64(Self.samplesPerPacket)
        var skip: Int64 = 0
        if abs(drift) > Int64(Self.sampleRate) * 2 {
            // A clock jump rather than a gap: keep the sound continuous.
            logInfo("audio: timestamps jumped \(drift) samples")
        } else if drift > slack {
            feedSilence(Int(drift))
        } else if drift < -slack {
            skip = -drift  // already covered, by silence or earlier audio
        }
        if skip >= Int64(pcm.frameLength) { return }
        feed(skip > 0 ? slice(pcm, from: Int(skip)) : pcm)
    }

    /// Fills with silence up to `sample` if app audio hasn't got that far.
    func fillSilence(upTo sample: Int64) {
        if sample > nextSample { feedSilence(Int(sample - nextSample)) }
    }

    /// AAC packets encoded since the last call.
    func takePackets() -> Packets? {
        guard !packets.isEmpty else { return nil }
        let taken = Packets(first: packetsTaken, data: packets)
        packetsTaken += Int64(packets.count)
        packets = []
        return taken
    }

    // MARK: - Encoding

    private func feed(_ pcm: AVAudioPCMBuffer) {
        nextSample += Int64(pcm.frameLength)
        encoderInput.append(pcm)
        while true {
            let output = AVAudioCompressedBuffer(format: encoder.outputFormat, packetCapacity: 32,
                                                 maximumPacketSize: encoder.maximumOutputPacketSize)
            var error: NSError?
            let status = encoder.convert(to: output, error: &error) { [unowned self] _, inputStatus in
                if self.encoderInput.isEmpty {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return self.encoderInput.removeFirst()
            }
            collect(output)
            if status == .error { logInfo("audio: encoder error \(error?.localizedDescription ?? "")") }
            if status != .haveData { break }
        }
    }

    private func collect(_ output: AVAudioCompressedBuffer) {
        guard output.packetCount > 0, let descriptions = output.packetDescriptions else { return }
        for i in 0..<Int(output.packetCount) {
            let description = descriptions[i]
            packets.append(Data(bytes: output.data.advanced(by: Int(description.mStartOffset)), count: Int(description.mDataByteSize)))
        }
    }

    private func feedSilence(_ count: Int) {
        var remaining = count
        while remaining > 0 {
            let frames = min(remaining, 4800)
            guard let silence = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let channels = silence.floatChannelData else { return }
            silence.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<Int(pcmFormat.channelCount) {
                channels[channel].initialize(repeating: 0, count: frames)
            }
            feed(silence)
            remaining -= frames
        }
    }

    /// Converts app audio to 48 kHz stereo float, keeping the converter
    /// between calls so resampling stays continuous.
    private func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == pcmFormat { return buffer }
        if resampler == nil || resampler?.inputFormat != buffer.format {
            resampler = AVAudioConverter(from: buffer.format, to: pcmFormat)
            logInfo("audio: app audio is \(Int(buffer.format.sampleRate)) Hz, \(buffer.format.channelCount) channels")
        }
        guard let resampler else { return nil }
        let ratio = pcmFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        _ = resampler.convert(to: output, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return output
    }

    private func slice(_ buffer: AVAudioPCMBuffer, from start: Int) -> AVAudioPCMBuffer {
        let frames = Int(buffer.frameLength) - start
        guard let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(frames)),
              let source = buffer.floatChannelData, let target = output.floatChannelData else { return buffer }
        output.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel] + start, count: frames)
        }
        return output
    }
}

public enum AudioSamples {
    /// Copies a ReplayKit audio sample buffer into an AVAudioPCMBuffer.
    /// ReplayKit's app audio can be big-endian, which AVAudioConverter
    /// doesn't take, so that gets byte-swapped here.
    public static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }
        var asbd = description.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let bigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        asbd.mFormatFlags &= ~kAudioFormatFlagIsBigEndian
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let pcmFormat = AVAudioFormat(streamDescription: &asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        if bigEndian { swapBytes(buffer.mutableAudioBufferList, bitsPerSample: Int(asbd.mBitsPerChannel)) }
        return buffer
    }

    static func swapBytes(_ list: UnsafeMutablePointer<AudioBufferList>, bitsPerSample: Int) {
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buffer.mData else { continue }
            let size = Int(buffer.mDataByteSize)
            switch bitsPerSample {
            case 16:
                let samples = data.assumingMemoryBound(to: UInt16.self)
                for i in 0..<size / 2 { samples[i] = samples[i].byteSwapped }
            case 32:
                let samples = data.assumingMemoryBound(to: UInt32.self)
                for i in 0..<size / 4 { samples[i] = samples[i].byteSwapped }
            default:
                break
            }
        }
    }
}
