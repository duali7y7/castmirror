import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

/// Turns screen frames and app audio into the fragmented MP4 chunks the
/// receiver plays: an init segment, then one fragment per video frame and
/// one per batch of audio packets.
///
/// Frames go out at a fixed rate: ReplayKit only delivers a frame when the
/// screen changes, so on each tick the newest frame is encoded again if
/// nothing new arrived. Sound and picture share one clock, the host time of
/// the first tick.
public final class MirrorStream: @unchecked Sendable {
    public struct Settings {
        public var fps = 30
        public var bitrate = 6_000_000
        public var maxWidth = 1920
        public var maxHeight = 1080

        public init() {}
    }

    public enum Chunk {
        case initSegment(Data)
        case video(Data, keyframe: Bool)
        case audio(Data)
    }

    /// Called on the stream's queue, in order.
    public var onChunk: ((Chunk) -> Void)?

    private let queue = DispatchQueue(label: "castmirror.stream", qos: .userInteractive)
    private let settings: Settings
    private let video: VideoEncoder
    private let audio: AudioEncoder?
    /// Video timestamps move later by the AAC encoder's start-up delay, so
    /// sound and picture line up.
    private let videoOffset: UInt64
    private var origin: Double?
    private var latest: (buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation)?
    private var prepared: CVPixelBuffer?
    private var lastIndex: Int64 = -1
    private var videoConfig: VideoTrackConfig?
    private var initSegment: Data?
    private var sequence: UInt32 = 0
    private var clock: DispatchSourceTimer?

    public init(settings: Settings = Settings()) {
        self.settings = settings
        video = VideoEncoder(settings: .init(maxWidth: settings.maxWidth, maxHeight: settings.maxHeight,
                                             fps: settings.fps, bitrate: settings.bitrate, keyframeInterval: settings.fps * 2))
        audio = AudioEncoder()
        if audio == nil { logInfo("audio: no AAC encoder, sending video only") }
        videoOffset = UInt64(AudioEncoder.primingSamples) * UInt64(FMP4.videoTimescale) / UInt64(AudioEncoder.sampleRate)
        video.onFrame = { [weak self] frame in
            self?.queue.async { self?.emitVideo(frame) }
        }
    }

    /// Hands over the newest screen frame. Safe from any thread.
    public func submitVideo(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        queue.async { self.latest = (buffer, orientation) }
    }

    /// Hands over app audio whose first sample played at `hostTime` seconds.
    /// Safe from any thread.
    public func submitAudio(_ buffer: AVAudioPCMBuffer, hostTime: Double) {
        queue.async {
            guard let audio = self.audio, let origin = self.origin else { return }
            let start = Int64(((hostTime - origin) * Double(AudioEncoder.sampleRate)).rounded())
            audio.append(buffer, startSample: start)
        }
    }

    /// Starts ticking once per frame on the host clock.
    public func startClock() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            let interval = 1.0 / Double(self.settings.fps)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.step(now: CMClockGetTime(CMClockGetHostTimeClock()).seconds) }
            timer.resume()
            self.clock = timer
        }
    }

    /// One frame interval, at `hostTime`. The clock calls this; tests call it
    /// directly with made-up times.
    public func tick(hostTime: Double) {
        queue.async { self.step(now: hostTime) }
    }

    public func requestKeyframe() {
        queue.async { self.video.requestKeyframe() }
    }

    /// The current init segment, for a receiver that connects mid-stream.
    /// Don't call from `onChunk`.
    public var currentInitSegment: Data? {
        queue.sync { initSegment }
    }

    /// Waits until everything submitted so far has come out as chunks.
    public func flush() {
        queue.sync { video.flush() }
        queue.sync { emitAudio() }
    }

    public func stop() {
        queue.sync {
            clock?.cancel()
            clock = nil
            video.invalidate()
        }
    }

    // MARK: - On the queue

    private func step(now: Double) {
        if origin == nil { origin = now }
        let elapsed = now - (origin ?? now)
        let index = Int64((elapsed * Double(settings.fps)).rounded())
        guard index > lastIndex else { return }
        lastIndex = index

        if let latest {
            // Let go of ReplayKit's buffer straight away; keep our copy for repeats.
            self.latest = nil
            if let buffer = video.prepare(latest.buffer, orientation: latest.orientation) { prepared = buffer }
        }
        if let prepared { video.encode(prepared, index: index) }

        if let audio {
            // Silence once app audio is more than 0.3 s behind (nothing playing).
            audio.fillSilence(upTo: Int64((elapsed - 0.3) * Double(AudioEncoder.sampleRate)))
            emitAudio()
        }
    }

    private func emitVideo(_ frame: VideoEncoder.Frame) {
        if frame.config != videoConfig {
            // A new size always starts with a keyframe.
            guard frame.isKeyframe else { return }
            videoConfig = frame.config
            let segment = FMP4.initSegment(video: frame.config, audio: audio?.config)
            initSegment = segment
            onChunk?(.initSegment(segment))
        }
        let frameTicks = UInt64(FMP4.videoTimescale) / UInt64(settings.fps)
        sequence += 1
        let fragment = FMP4.fragment(
            sequence: sequence, track: FMP4.videoTrack,
            baseDecodeTime: UInt64(max(0, frame.index)) * frameTicks + videoOffset,
            samples: [MP4Sample(data: frame.data, duration: UInt32(frameTicks), isSync: frame.isKeyframe)])
        onChunk?(.video(fragment, keyframe: frame.isKeyframe))
    }

    private func emitAudio() {
        guard let audio, let packets = audio.takePackets() else { return }
        // Audio before the first init segment has nothing to belong to.
        guard initSegment != nil else { return }
        sequence += 1
        let samples = packets.data.map { MP4Sample(data: $0, duration: UInt32(AudioEncoder.samplesPerPacket), isSync: true) }
        let fragment = FMP4.fragment(
            sequence: sequence, track: FMP4.audioTrack,
            baseDecodeTime: UInt64(packets.first) * UInt64(AudioEncoder.samplesPerPacket),
            samples: samples)
        onChunk?(.audio(fragment))
    }
}
