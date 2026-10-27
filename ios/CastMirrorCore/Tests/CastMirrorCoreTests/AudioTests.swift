import AVFoundation
@testable import CastMirrorCore
import CoreMedia
import XCTest

final class AudioTests: XCTestCase {
    /// ReplayKit can hand over big-endian 16-bit app audio.
    func testBigEndianSampleBuffersAreSwapped() throws {
        let frames = 1024
        var values = [UInt16](repeating: 0, count: frames * 2)
        for i in values.indices { values[i] = UInt16(bitPattern: Int16(i % 1000 - 500)).bigEndian }
        let sample = try makeSampleBuffer(values, sampleRate: 44100,
                                          flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian)

        let pcm = try XCTUnwrap(AudioSamples.pcmBuffer(from: sample))
        XCTAssertEqual(pcm.frameLength, AVAudioFrameCount(frames))
        XCTAssertEqual(pcm.format.sampleRate, 44100)
        let ints = try XCTUnwrap(pcm.int16ChannelData)[0]
        XCTAssertEqual(ints[0], -500)
        XCTAssertEqual(ints[1], -499)
        XCTAssertEqual(ints[999], 499)
    }

    /// One continuous AAC stream: app audio at another rate, then silence.
    func testEncodesContinuousAAC() throws {
        let encoder = try XCTUnwrap(AudioEncoder())
        let tone = ToneGenerator(sampleRate: 44100)
        var position = 0.0
        while position < 1 {
            encoder.append(tone.next(frames: 1024), startSample: Int64((position * 48000).rounded()))
            position += 1024 / 44100
        }
        // 44 buffers of 1024 at 44.1 kHz is 1.02 s, less what the resampler holds back.
        XCTAssertEqual(Double(encoder.nextSample), 49041, accuracy: 300)
        encoder.fillSilence(upTo: 96000)
        XCTAssertEqual(encoder.nextSample, 96000)

        var packets = 0
        while let batch = encoder.takePackets() {
            XCTAssertEqual(batch.first, Int64(packets))
            packets += batch.data.count
            XCTAssertTrue(batch.data.allSatisfy { !$0.isEmpty && $0.count < 2048 })
        }
        // 2 s at 48 kHz is 93.75 packets; the encoder holds back a few.
        XCTAssertGreaterThan(packets, 85)
        XCTAssertLessThanOrEqual(packets, 96)
    }

    /// A gap in app audio is filled with silence; overlapping audio is trimmed.
    func testGapsAndOverlaps() throws {
        let encoder = try XCTUnwrap(AudioEncoder())
        let tone = ToneGenerator(sampleRate: 48000)
        encoder.append(tone.next(frames: 4800), startSample: 0)
        XCTAssertEqual(encoder.nextSample, 4800)
        encoder.append(tone.next(frames: 4800), startSample: 24000)  // 400 ms gap
        XCTAssertEqual(encoder.nextSample, 28800)
        encoder.append(tone.next(frames: 4800), startSample: 26000)  // overlaps by 2800
        XCTAssertEqual(encoder.nextSample, 28800 + 2000)
    }

    /// Switched on partway through a stream, AAC starts at that time, on a
    /// whole packet.
    func testAACStartsPartWay() throws {
        let encoder = try XCTUnwrap(AudioEncoder(startSample: 100_000))
        XCTAssertEqual(encoder.nextSample, 97 * 1024)
        encoder.fillSilence(upTo: 150_000)
        XCTAssertEqual(encoder.takePackets()?.first, 97)
    }

    /// Separate sound: 'cmau' chunks of 16-bit stereo, back to back unless
    /// the timestamps jump.
    func testPCMChunks() throws {
        let packer = try XCTUnwrap(PCMPacker())
        let tone = ToneGenerator(sampleRate: 48000)
        let first = try XCTUnwrap(packer.chunk(for: tone.next(frames: 1024), startSample: 0))
        XCTAssertEqual(first.count, 16 + 1024 * 4)
        XCTAssertEqual(Box.read(first).first?.type, "cmau")
        XCTAssertEqual(header(first).size, 16 + 4096)
        XCTAssertEqual(header(first).first, 0)
        // Left and right of the second frame: 0.3 * sin(2π·440/48000).
        let expected = Int((0.3 * sin(2 * Double.pi * 440 / 48000) * 32768).rounded())
        XCTAssertLessThanOrEqual(abs(Int(sample(first, frame: 1, channel: 0)) - expected), 1)
        XCTAssertEqual(sample(first, frame: 1, channel: 1), sample(first, frame: 1, channel: 0))

        let next = try XCTUnwrap(packer.chunk(for: tone.next(frames: 1024), startSample: 1030))
        XCTAssertEqual(header(next).first, 1024, "a few samples of timestamp jitter keep it back to back")
        let jumped = try XCTUnwrap(packer.chunk(for: tone.next(frames: 1024), startSample: 50_000))
        XCTAssertEqual(header(jumped).first, 50_000)
    }

    private func header(_ chunk: Data) -> (size: UInt32, first: Int64) {
        let bytes = [UInt8](chunk.prefix(16))
        let size = bytes[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let first = bytes[8..<16].reduce(Int64(0)) { $0 << 8 | Int64($1) }
        return (size, first)
    }

    private func sample(_ chunk: Data, frame: Int, channel: Int) -> Int16 {
        let offset = chunk.startIndex + 16 + frame * 4 + channel * 2
        return Int16(bitPattern: UInt16(chunk[offset]) | UInt16(chunk[offset + 1]) << 8)
    }

    private func makeSampleBuffer(_ interleaved: [UInt16], sampleRate: Double, flags: AudioFormatFlags) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                      magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        let byteCount = interleaved.count * 2
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                                                          customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                                          flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block), noErr)
        let blockBuffer = try XCTUnwrap(block)
        interleaved.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: try XCTUnwrap(format), sampleCount: interleaved.count / 2,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

/// A 440 Hz tone in the standard float format at any sample rate.
final class ToneGenerator {
    let format: AVAudioFormat
    private var phase = 0.0

    init(sampleRate: Double) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }

    func next(frames: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let step = 2 * Double.pi * 440 / format.sampleRate
        for i in 0..<frames {
            let value = Float(sin(phase) * 0.3)
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
            phase += step
        }
        return buffer
    }
}
