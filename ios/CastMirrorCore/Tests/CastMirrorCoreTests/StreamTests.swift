import AVFoundation
@testable import CastMirrorCore
import CoreVideo
import XCTest

final class StreamTests: XCTestCase {
    func testOutputSizeFollowsOrientation() {
        let encoder = VideoEncoder(settings: .init())
        // iPhone 15 screen buffers are 1179x2556, portrait.
        let portrait = encoder.outputGeometry(width: 1179, height: 2556, orientation: .up)
        XCTAssertEqual([portrait.width, portrait.height], [498, 1080])
        let landscape = encoder.outputGeometry(width: 1179, height: 2556, orientation: .right)
        XCTAssertEqual([landscape.width, landscape.height], [1920, 886])
        XCTAssertEqual(landscape.turn, .counterclockwise)
        XCTAssertEqual(encoder.outputGeometry(width: 1179, height: 2556, orientation: .left).turn, .clockwise)
    }

    /// The stream is picture only unless sound is asked for. Saved as
    /// `landscape-video.mp4` for replaying on a Chromecast, like the
    /// landscape test below.
    func testNoSoundByDefault() throws {
        let chunks = try record(seconds: 10, orientations: [.right], sounds: nil)
        guard case .initSegment(let segment) = chunks.first else { return XCTFail("stream must start with the init segment") }
        XCTAssertEqual(trackCount(segment), 1)
        XCTAssertFalse(chunks.contains { if case .audio = $0 { return true } else { return false } })
        XCTAssertGreaterThanOrEqual(chunks.count, 286)
        // Without the AAC start-up delay, video starts at zero.
        guard chunks.count > 1, case .video(let first, _) = chunks[1] else { return XCTFail("the init segment must be followed by video") }
        XCTAssertEqual(decodeTime(of: first), 0)
        try saveSample(chunks, as: "landscape-video.mp4")
    }

    /// Ten seconds of a landscape screen with a tone, end to end. With
    /// CASTMIRROR_SAMPLE_OUT set, the stream is saved there, so it can be
    /// checked with FFmpeg and played on a Chromecast with
    /// `npm start -- --source replay --file landscape.mp4`.
    func testLandscapeStreamWithSound() throws {
        let chunks = try record(seconds: 10, orientations: [.right], sounds: [.tvInVideo])
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
        XCTAssertGreaterThanOrEqual(video.filter { $0.1 }.count, 5, "a keyframe every 2 s")
        XCTAssertGreaterThan(audio.count, 200)

        // Video decode times are whole frames (3000 at 90 kHz), starting at
        // the AAC priming offset.
        let times = video.map { decodeTime(of: $0.0) }
        XCTAssertEqual(times.first, 3960)
        XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(times.allSatisfy { $0 >= 3960 && ($0 - 3960) % 3000 == 0 })
        XCTAssertLessThanOrEqual(times.last ?? 0, 3960 + 299 * 3000)

        try saveSample(chunks, as: "landscape.mp4")
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

    /// "TV, low delay": picture-only MP4 plus 'cmau' PCM chunks, back to
    /// back. Saved as `landscape-tv.mp4`, which the PC sender's replay plays
    /// on the Chromecast with its sound.
    func testSeparateSound() throws {
        let chunks = try record(seconds: 10, orientations: [.right], sounds: [.tv])
        guard case .initSegment(let segment) = chunks.first else { return XCTFail("stream must start with the init segment") }
        XCTAssertEqual(trackCount(segment), 1)

        let sound = pcmChunks(chunks)
        XCTAssertEqual(sound.count, chunks.filter { if case .audio = $0 { return true } else { return false } }.count,
                       "all sound comes as cmau chunks")
        XCTAssertGreaterThan(sound.count, 400)
        for (previous, chunk) in zip(sound, sound.dropFirst()) {
            XCTAssertEqual(chunk.first, previous.first + Int64(previous.frames), "chunks follow each other exactly")
        }
        let total = sound.reduce(0) { $0 + $1.frames }
        XCTAssertEqual(Double(total) / 48000, 10, accuracy: 0.3)
        try saveSample(chunks, as: "landscape-tv.mp4")
    }

    /// The sound setting changes while streaming: iPhone, then sound inside
    /// the video, then sound beside it, each starting from the time of the switch.
    func testSwitchingSoundWhileStreaming() throws {
        let chunks = try record(seconds: 6, orientations: [.right], sounds: [.phone, .tvInVideo, .tv])
        let inits = chunks.enumerated().compactMap { index, chunk -> (Int, Data)? in
            if case .initSegment(let data) = chunk { return (index, data) } else { return nil }
        }
        XCTAssertEqual(inits.map { trackCount($0.1) }, [1, 2, 1])
        guard inits.count == 3 else { return }

        let aac = chunks.enumerated().compactMap { index, chunk -> (Int, UInt64)? in
            guard case .audio(let data) = chunk, Box.read(data).first?.type == "moof" else { return nil }
            return (index, decodeTime(of: data))
        }
        XCTAssertTrue(aac.allSatisfy { $0.0 > inits[1].0 && $0.0 < inits[2].0 }, "AAC only while it's switched on")
        // Switched on at 2 s: AAC starts there, not at the stream's start.
        XCTAssertEqual(Double(aac.first?.1 ?? 0) / 48000, 2, accuracy: 0.25)

        let pcmIndexes = chunks.indices.filter { index in
            if case .audio(let data) = chunks[index] { return Box.read(data).first?.type == "cmau" } else { return false }
        }
        XCTAssertTrue(pcmIndexes.allSatisfy { $0 > inits[2].0 }, "separate sound only after switching to it")
        XCTAssertEqual(Double(pcmChunks(chunks).first?.first ?? 0) / 48000, 4, accuracy: 0.25)
    }

    /// App audio that arrives 0.6 s after its timestamps still plays: the
    /// silence that fills gaps waits for it instead of taking its place.
    func testLateAppAudioIsNotReplacedBySilence() throws {
        var dropped = 0.0
        _ = try record(seconds: 4, orientations: [.right], sounds: [.tvInVideo], audioDelay: 0.6) { stream in
            dropped = stream.droppedAudioSeconds
        }
        // Only the start is lost, while the stream learns how late it comes.
        XCTAssertLessThan(dropped, 0.5)
    }

    /// Feeds made-up screen frames and a 44.1 kHz tone through a stream,
    /// faster than real time, switching orientation and sound at equal
    /// intervals. `sounds` nil leaves the stream's default. The tone arrives
    /// `audioDelay` seconds after its timestamps.
    private func record(seconds: Int, orientations: [CGImagePropertyOrientation], sounds: [SoundMode]? = [.tvInVideo],
                        audioDelay: Double = 0, inspect: ((MirrorStream) -> Void)? = nil) throws -> [MirrorStream.Chunk] {
        var settings = MirrorStream.Settings()
        if let sound = sounds?.first { settings.sound = sound }
        let stream = MirrorStream(settings: settings)
        let lock = NSLock()
        var chunks: [MirrorStream.Chunk] = []
        stream.onChunk = { chunk in lock.withLock { chunks.append(chunk) } }

        let screen = try XCTUnwrap(SyntheticScreen(width: 1179, height: 2556))
        let tone = ToneGenerator(sampleRate: 44100)
        let origin = 5000.0
        let frames = seconds * 30
        var audioTime = 0.0
        var sound = sounds?.first
        for i in 0..<frames {
            let time = Double(i) / 30
            let orientation = orientations[i * orientations.count / frames]
            if let sounds, sounds[i * sounds.count / frames] != sound {
                sound = sounds[i * sounds.count / frames]
                stream.setSound(sound!)
            }
            stream.submitVideo(screen.frame(i), orientation: orientation)
            stream.tick(hostTime: origin + time)
            while audioTime < time + 1.0 / 30 - audioDelay {
                stream.submitAudio(tone.next(frames: 1024), hostTime: origin + audioTime)
                audioTime += 1024 / 44100
            }
            if i % 30 == 29 { stream.flush() }  // keep the real-time encoder from falling behind
        }
        stream.flush()
        inspect?(stream)
        stream.stop()
        return lock.withLock { chunks }
    }

    private func trackCount(_ initSegment: Data) -> Int {
        Box.read(initSegment).last?.children.filter { $0.type == "trak" }.count ?? 0
    }

    /// The 'cmau' chunks in a stream: first sample and number of frames.
    private func pcmChunks(_ chunks: [MirrorStream.Chunk]) -> [(first: Int64, frames: Int)] {
        chunks.compactMap { chunk in
            guard case .audio(let data) = chunk, let box = Box.read(data).first, box.type == "cmau" else { return nil }
            let first = Int64(box.u32(at: 0)) << 32 | Int64(box.u32(at: 4))
            return (first, (box.body.count - 8) / 4)
        }
    }

    /// Writes the stream to CASTMIRROR_SAMPLE_OUT, if set.
    private func saveSample(_ chunks: [MirrorStream.Chunk], as name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["CASTMIRROR_SAMPLE_OUT"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try chunks.reduce(into: Data()) { all, chunk in
            switch chunk {
            case .initSegment(let data), .video(let data, _), .audio(let data): all.append(data)
            }
        }.write(to: url)
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
