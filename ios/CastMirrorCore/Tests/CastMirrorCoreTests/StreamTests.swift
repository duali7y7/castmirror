import AVFoundation
@testable import CastMirrorCore
import CoreVideo
import XCTest

final class StreamTests: XCTestCase {
    func testOutputSizeFollowsOrientation() {
        let encoder = VideoEncoder(settings: .init())
        // iPhone 15 screen buffers are 1179x2556, portrait.
        let portrait = encoder.geometry(width: 1179, height: 2556, orientation: .up)
        XCTAssertEqual([portrait.width, portrait.height], [498, 1080])
        let landscape = encoder.geometry(width: 1179, height: 2556, orientation: .right)
        XCTAssertEqual([landscape.width, landscape.height], [1920, 886])
        XCTAssertEqual(landscape.turn, .clockwise)
        XCTAssertEqual(encoder.geometry(width: 1179, height: 2556, orientation: .left).turn, .counterclockwise)
    }

    /// Ten seconds of a landscape screen with a tone, end to end. With
    /// CASTMIRROR_SAMPLE_OUT set, the stream is saved there, so it can be
    /// checked with FFmpeg and played on a Chromecast with
    /// `npm start -- --source replay --file landscape.mp4`.
    func testLandscapeStreamWithSound() throws {
        let chunks = try record(seconds: 10, orientations: [.right])
        let inits = chunks.filter { if case .initSegment = $0 { return true } else { return false } }
        XCTAssertEqual(inits.count, 1)
        guard case .initSegment(let segment) = chunks.first else { return XCTFail("stream must start with the init segment") }
        XCTAssertEqual(Box.read(segment).map(\.type), ["ftyp", "moov"])

        let video = chunks.compactMap { chunk -> (Data, Bool)? in
            if case .video(let data, let keyframe) = chunk { return (data, keyframe) } else { return nil }
        }
        let audio = chunks.compactMap { chunk -> Data? in
            if case .audio(let data) = chunk { return data } else { return nil }
        }
        // A real-time encoder may drop the odd frame when fed faster than real time.
        XCTAssertGreaterThanOrEqual(video.count, 285)
        XCTAssertTrue(video.first?.1 ?? false, "the first frame must be a keyframe")
        XCTAssertGreaterThanOrEqual(video.filter(\.1).count, 5, "a keyframe every 2 s")
        XCTAssertGreaterThan(audio.count, 200)

        // Video decode times are whole frames (3000 at 90 kHz), starting at
        // the AAC priming offset.
        let times = video.map { decodeTime(of: $0.0) }
        XCTAssertEqual(times.first, 3960)
        XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(times.allSatisfy { $0 >= 3960 && ($0 - 3960) % 3000 == 0 })
        XCTAssertLessThanOrEqual(times.last ?? 0, 3960 + 299 * 3000)

        if let directory = ProcessInfo.processInfo.environment["CASTMIRROR_SAMPLE_OUT"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("landscape.mp4")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try chunks.reduce(into: Data()) { all, chunk in
                switch chunk {
                case .initSegment(let data), .video(let data, _), .audio(let data): all.append(data)
                }
            }.write(to: url)
        }
    }

    /// Turning the phone starts a new init segment at the new size.
    func testRotationStartsANewStream() throws {
        let chunks = try record(seconds: 2, orientations: [.up, .right])
        let sizes = chunks.compactMap { chunk -> [UInt32]? in
            guard case .initSegment(let data) = chunk,
                  let tkhd = Box.read(data).last?.child("trak")?.child("tkhd") else { return nil }
            return [tkhd.u32(at: 76) >> 16, tkhd.u32(at: 80) >> 16]
        }
        XCTAssertEqual(sizes, [[498, 1080], [1920, 886]])
    }

    /// Feeds made-up screen frames and a 44.1 kHz tone through a stream,
    /// faster than real time, switching orientation at equal intervals.
    private func record(seconds: Int, orientations: [CGImagePropertyOrientation]) throws -> [MirrorStream.Chunk] {
        let stream = MirrorStream()
        let lock = NSLock()
        var chunks: [MirrorStream.Chunk] = []
        stream.onChunk = { chunk in lock.withLock { chunks.append(chunk) } }

        let screen = try XCTUnwrap(SyntheticScreen(width: 1179, height: 2556))
        let tone = ToneGenerator(sampleRate: 44100)
        let origin = 5000.0
        let frames = seconds * 30
        var audioTime = 0.0
        for i in 0..<frames {
            let time = Double(i) / 30
            let orientation = orientations[i * orientations.count / frames]
            stream.submitVideo(screen.frame(i), orientation: orientation)
            stream.tick(hostTime: origin + time)
            while audioTime < time + 1.0 / 30 {
                stream.submitAudio(tone.next(frames: 1024), hostTime: origin + audioTime)
                audioTime += 1024 / 44100
            }
            if i % 30 == 29 { stream.flush() }  // keep the real-time encoder from falling behind
        }
        stream.flush()
        stream.stop()
        return lock.withLock { chunks }
    }

    private func decodeTime(of fragment: Data) -> UInt64 {
        guard let tfdt = Box.read(fragment).first?.child("traf")?.child("tfdt") else { return 0 }
        return UInt64(tfdt.u32(at: 4)) << 32 | UInt64(tfdt.u32(at: 8))
    }
}

/// Portrait screen frames like ReplayKit's (full-range 4:2:0), with a bar
/// that moves so every frame differs.
final class SyntheticScreen {
    let width: Int
    let height: Int
    private var pool: CVPixelBufferPool?

    init?(width: Int, height: Int) {
        self.width = width
        self.height = height
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        if pool == nil { return nil }
    }

    func frame(_ index: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }

        let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bar = (index * 24) % height
        for y in 0..<height {
            let value: UInt8 = abs(y - bar) < 40 ? 235 : UInt8(16 + (y * 180 / height))
            memset(luma + y * lumaRow, Int32(value), width)
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        for y in 0..<height / 2 {
            let row = chroma + y * chromaRow
            for x in 0..<width / 2 {
                row[2 * x] = UInt8(64 + x * 128 / (width / 2))   // Cb
                row[2 * x + 1] = 128                             // Cr
            }
        }
        return pixels
    }
}
