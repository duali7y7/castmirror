import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

/// Turns screen frames and app audio into the chunks the receiver plays: an
/// MP4 init segment, then one fragment per video frame, with the sound as
/// the SoundMode says: none, AAC fragments inside the MP4 stream, or PCM
/// chunks apart from it.
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
        /// Where the sound plays at the start; setSound(_:) changes it.
        public var sound = SoundMode.phone

        public init() {}
    }

    public enum Chunk {
        case initSegment(Data)
        case video(Data, keyframe: Bool)
        case audio(Data)
    }

    /// Called on the stream's queue, in order.
    public var onChunk: ((Chunk) -> Void)?

    /// Video timestamps move later by the AAC encoder's start-up delay when
    /// the stream carries AAC, so sound and picture line up.
    private static let aacVideoOffset = UInt64(AudioEncoder.primingSamples) * UInt64(FMP4.videoTimescale) / UInt64(AudioEncoder.sampleRate)

    private let queue = DispatchQueue(label: "castmirror.stream", qos: .userInteractive)
    private let settings: Settings
    private let video: VideoEncoder
    private let soundLock = NSLock()
    private var wantedSound: SoundMode  // under soundLock: ReplayKit's thread reads it
    private var sound: SoundMode        // on the queue
    private var aac: AudioEncoder?
    private var pcm: PCMPacker?
    private var initSound: SoundMode?
    private var initHasAAC = false
    private var origin: Double?
    private var elapsed = 0.0
    private var latest: (buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation)?
    private var prepared: CVPixelBuffer?
    private var lastIndex: Int64 = -1
    private var videoConfig: VideoTrackConfig?
    private var initSegment: Data?
    private var sequence: UInt32 = 0
    private var clock: DispatchSourceTimer?
    /// How late app audio arrives after its timestamp (s): rises at once,
    /// falls slowly. Silence waits that long before taking its place.
    private var audioLag = 0.0
    private var audioStats = AudioStats()
    private var droppedReported: Int64 = 0

    private struct AudioStats {
        var buffers = 0
        var seconds = 0.0
        var peak: Float = 0
        var latest = -Double.infinity
    }

    public init(settings: Settings = Settings()) {
        self.settings = settings
        wantedSound = settings.sound
        sound = settings.sound
        video = VideoEncoder(settings: .init(maxWidth: settings.maxWidth, maxHeight: settings.maxHeight,
                                             fps: settings.fps, bitrate: settings.bitrate, keyframeInterval: settings.fps * 2))
        startSound()
        video.onFrame = { [weak self] frame in
            self?.queue.async { self?.emitVideo(frame) }
        }
    }

    /// Hands over the newest screen frame. Safe from any thread.
    public func submitVideo(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        queue.async { self.latest = (buffer, orientation) }
    }

    /// Whether app audio is used at all, to skip converting it otherwise.
    /// Safe from any thread.
    public var wantsAudio: Bool {
        soundLock.withLock { wantedSound != .phone }
    }

    /// Hands over app audio whose first sample played at `hostTime` seconds.
    /// Safe from any thread.
    public func submitAudio(_ buffer: AVAudioPCMBuffer, hostTime: Double) {
        queue.async {
            guard let origin = self.origin, self.aac != nil || self.pcm != nil else { return }
            let start = Int64(((hostTime - origin) * Double(AudioEncoder.sampleRate)).rounded())
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            let lateness = self.elapsed - (hostTime - origin + duration)
            self.audioLag = max(self.audioLag, min(1.2, lateness))
            self.audioStats.buffers += 1
            self.audioStats.seconds += duration
            self.audioStats.peak = max(self.audioStats.peak, Self.peak(of: buffer))
            self.audioStats.latest = max(self.audioStats.latest, lateness)

            self.aac?.append(buffer, startSample: start)
            // Separate sound once the stream it goes with has started.
            if let pcm = self.pcm, self.initSound == .tv, let chunk = pcm.chunk(for: buffer, startSample: start) {
                self.onChunk?(.audio(chunk))
            }
        }
    }

    /// Changes where the sound plays, while streaming. Sound inside the video
    /// stream switches on or off with a new init segment at the next
    /// keyframe, which makes the receiver start a fresh stream.
    public func setSound(_ mode: SoundMode) {
        soundLock.withLock { wantedSound = mode }
        queue.async {
            guard mode != self.sound else { return }
            self.sound = mode
            logInfo("sound: \(mode.rawValue)")
            self.startSound()
            self.video.requestKeyframe()
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

    /// What app audio did since the last call, for the logs; nil while the
    /// sound stays on the phone. Don't call from `onChunk`.
    public func audioSummary() -> String? {
        queue.sync {
            guard sound != .phone else { return nil }
            let stats = audioStats
            audioStats = AudioStats()
            guard stats.buffers > 0 else {
                return "sound \(sound.rawValue): no app audio (Apple Music and some other apps block capture)"
            }
            let peak = stats.peak > 0 ? String(format: "peak %.0f dB", 20 * log10(stats.peak)) : "silent"
            var text = String(format: "sound %@: %.1f s from apps, %@, up to %.0f ms late", sound.rawValue, stats.seconds, peak,
                              max(0, stats.latest) * 1000)
            if let aac {
                let dropped = aac.droppedSamples - droppedReported
                droppedReported = aac.droppedSamples
                text += String(format: ", %.1f s dropped as late", Double(dropped) / Double(AudioEncoder.sampleRate))
            }
            return text
        }
    }

    /// App audio dropped as late so far in "TV, steady", for the tests.
    var droppedAudioSeconds: Double {
        queue.sync { Double(aac?.droppedSamples ?? 0) / Double(AudioEncoder.sampleRate) }
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

    /// Sets up the encoder for `sound`, starting from the current time.
    private func startSound() {
        let now = Int64(elapsed * Double(AudioEncoder.sampleRate))
        aac = sound == .tvInVideo ? AudioEncoder(startSample: now) : nil
        if sound == .tvInVideo && aac == nil { logInfo("audio: no AAC encoder, sending video only") }
        pcm = sound == .tv ? PCMPacker() : nil
        droppedReported = 0
    }

    private func step(now: Double) {
        if origin == nil { origin = now }
        elapsed = now - (origin ?? now)
        let index = Int64((elapsed * Double(settings.fps)).rounded())
        guard index > lastIndex else { return }
        lastIndex = index

        if let latest {
            // Let go of ReplayKit's buffer straight away; keep our copy for repeats.
            self.latest = nil
            if let buffer = video.prepare(latest.buffer, orientation: latest.orientation) { prepared = buffer }
        }
        if let prepared { video.encode(prepared, index: index) }

        audioLag = max(0, audioLag - 0.02 / Double(settings.fps))  // 20 ms a second
        if let aac {
            // Silence once app audio is well behind (nothing playing). Late
            // app audio must get there first, or the silence replaces it.
            let wait = max(0.3, min(1.5, audioLag + 0.15))
            aac.fillSilence(upTo: Int64((elapsed - wait) * Double(AudioEncoder.sampleRate)))
            emitAudio()
        }
    }

    private func emitVideo(_ frame: VideoEncoder.Frame) {
        if (frame.config != videoConfig || initSound != sound) && frame.isKeyframe {
            videoConfig = frame.config
            initSound = sound
            initHasAAC = aac != nil
            let segment = FMP4.initSegment(video: frame.config, audio: initHasAAC ? aac?.config : nil)
            initSegment = segment
            onChunk?(.initSegment(segment))
        } else if frame.config != videoConfig {
            return  // a new size starts with its keyframe
        }
        let frameTicks = UInt64(FMP4.videoTimescale) / UInt64(settings.fps)
        sequence += 1
        let fragment = FMP4.fragment(
            sequence: sequence, track: FMP4.videoTrack,
            baseDecodeTime: UInt64(max(0, frame.index)) * frameTicks + (initHasAAC ? Self.aacVideoOffset : 0),
            samples: [MP4Sample(data: frame.data, duration: UInt32(frameTicks), isSync: frame.isKeyframe)])
        onChunk?(.video(fragment, keyframe: frame.isKeyframe))
    }

    private func emitAudio() {
        guard let aac, let packets = aac.takePackets() else { return }
        // Audio before an init segment with its track has nothing to belong to.
        guard initHasAAC else { return }
        sequence += 1
        let samples = packets.data.map { MP4Sample(data: $0, duration: UInt32(AudioEncoder.samplesPerPacket), isSync: true) }
        let fragment = FMP4.fragment(
            sequence: sequence, track: FMP4.audioTrack,
            baseDecodeTime: UInt64(packets.first) * UInt64(AudioEncoder.samplesPerPacket),
            samples: samples)
        onChunk?(.audio(fragment))
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let count = interleaved ? frames * channels : frames
        let planes = interleaved ? 1 : channels
        var peak: Float = 0
        if let data = buffer.floatChannelData {
            for plane in 0..<planes { for i in 0..<count { peak = max(peak, abs(data[plane][i])) } }
        } else if let data = buffer.int16ChannelData {
            for plane in 0..<planes { for i in 0..<count { peak = max(peak, abs(Float(data[plane][i])) / 32768) } }
        } else if let data = buffer.int32ChannelData {
            for plane in 0..<planes { for i in 0..<count { peak = max(peak, abs(Float(data[plane][i])) / 2_147_483_648) } }
        }
        return peak
    }
}
