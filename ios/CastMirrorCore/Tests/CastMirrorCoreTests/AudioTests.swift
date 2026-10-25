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
