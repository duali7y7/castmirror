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
    private(set) var nextSample: Int64
    /// App audio dropped because silence or earlier audio already covered
    /// its time, in samples.
    private(set) var droppedSamples: Int64 = 0

    private let pcmFormat: AVAudioFormat
    private let encoder: AVAudioConverter
    private let resampler: AudioResampler
    private var encoderInput: [AVAudioPCMBuffer] = []
    private var packets: [Data] = []
    private var packetsTaken: Int64

    /// Starts at `startSample` (rounded down to a whole packet), for sound
    /// switched on partway through a stream.
    init?(startSample: Int64 = 0) {
        guard let resampler = AudioResampler() else { return nil }
        let pcm = resampler.outputFormat
        let packet = Int64(Self.samplesPerPacket)
        packetsTaken = max(0, startSample) / packet
        nextSample = packetsTaken * packet
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
        self.resampler = resampler
    }

    /// Adds app audio that starts at `startSample` (48 kHz, from the stream's
    /// start), in any PCM format.
    func append(_ buffer: AVAudioPCMBuffer, startSample: Int64) {
        guard let pcm = resampler.convert(buffer), pcm.frameLength > 0 else { return }
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
        droppedSamples += min(skip, Int64(pcm.frameLength))
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

/// Converts app audio to 48 kHz stereo float, keeping the converter between
/// calls so resampling stays continuous.
final class AudioResampler {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init?() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(AudioEncoder.sampleRate),
                                         channels: AVAudioChannelCount(AudioEncoder.channels)) else { return nil }
        outputFormat = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == outputFormat { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            logInfo("audio: app audio is \(Int(buffer.format.sampleRate)) Hz, \(buffer.format.channelCount) channels")
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, inputStatus in
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
}

/// Sound sent apart from the picture (SoundMode.tv): 16-bit stereo PCM at
/// 48 kHz in 'cmau' chunks shaped like MP4 boxes:
///   u32 size, 'cmau', u64 first sample (48 kHz, from the stream's start),
///   then little-endian samples, left and right interleaved.
/// Same as pc-sender/src/pcm.js; receiver/receiver.js plays them with Web
/// Audio, lined up with the video by the sample number.
final class PCMPacker {
    static let headerSize = 16

    /// Sample number the next chunk starts at, when back to back.
    private(set) var nextSample: Int64?
    private let resampler: AudioResampler

    init?() {
        guard let resampler = AudioResampler() else { return nil }
        self.resampler = resampler
    }

    /// One chunk for app audio that starts at `startSample`.
    func chunk(for buffer: AVAudioPCMBuffer, startSample: Int64) -> Data? {
        guard let pcm = resampler.convert(buffer), pcm.frameLength > 0,
              let channels = pcm.floatChannelData else { return nil }
        let frames = Int(pcm.frameLength)
        // Back to back with the last chunk unless the timestamps jumped.
        var first = startSample
        if let next = nextSample, abs(startSample - next) <= Int64(AudioEncoder.samplesPerPacket) { first = next }
        nextSample = first + Int64(frames)

        var data = Data(count: Self.headerSize + frames * 4)
        data.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(raw.count).bigEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(0x636d_6175).bigEndian, toByteOffset: 4, as: UInt32.self)  // 'cmau'
            raw.storeBytes(of: UInt64(first).bigEndian, toByteOffset: 8, as: UInt64.self)
            let left = channels[0]
            let right = pcm.format.channelCount > 1 ? channels[1] : channels[0]
            for i in 0..<frames {
                let offset = Self.headerSize + i * 4
                raw.storeBytes(of: Self.int16(left[i]).littleEndian, toByteOffset: offset, as: Int16.self)
                raw.storeBytes(of: Self.int16(right[i]).littleEndian, toByteOffset: offset + 2, as: Int16.self)
            }
        }
        return data
    }

    private static func int16(_ value: Float) -> Int16 {
        Int16(max(-32768, min(32767, (value * 32768).rounded())))
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
