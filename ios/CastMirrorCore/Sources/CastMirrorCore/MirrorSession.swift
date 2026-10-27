import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

struct MirrorError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

/// One broadcast: serves the receiver page from the phone, opens it on the
/// Chromecast through DashCast, and streams the screen and app audio to it
/// over a WebSocket. Never queues frames: when the Wi-Fi backs up, video is
/// dropped until the next keyframe (audio keeps going).
public final class MirrorSession: @unchecked Sendable {
    /// Called once when the broadcast has to stop, with the reason to show.
    public var onFatalError: ((String) -> Void)?

    private let stream: MirrorStream
    private let http: HTTPServer
    private let webSocket = WebSocketServer()
    private let cast = CastClient()
    private let backlogLimit: Int
    private let lock = NSLock()
    private var waitingForKeyframe = true
    private var keyframeRequested = false
    private var dropped = 0
    private var stopped = false
    private var showStats: Bool

    public init(receiverDirectory: URL?, settings: MirrorStream.Settings = .init(), showStats: Bool = false) {
        stream = MirrorStream(settings: settings)
        http = HTTPServer(receiverDirectory: receiverDirectory)
        // About 0.3 s of video.
        backlogLimit = max(256 * 1024, settings.bitrate / 8 * 3 / 10)
        self.showStats = showStats
    }

    /// Shows or hides the stats overlay on the TV, straight away if it's connected.
    public func setShowStats(_ show: Bool) {
        lock.withLock { showStats = show }
        sendJSON(["type": "overlay", "show": show])
    }

    public func start() {
        stream.onChunk = { [weak self] chunk in self?.send(chunk) }
        webSocket.onConnect = { [weak self] in self?.receiverConnected() }
        webSocket.onText = { [weak self] text in self?.receiverMessage(text) }
        webSocket.onDisconnect = { logInfo("receiver disconnected") }
        cast.onEvent = { [weak self] event in
            switch event {
            case .appStopped: self?.fail("CastMirror was closed on the TV.")
            case .disconnected: self?.fail("Lost the connection to the Chromecast.")
            }
        }
        Log.shared.sink = { [weak self] line in self?.sendJSON(["type": "log", "msg": line]) }
        Task {
            do {
                try await self.run()
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    public func handleVideo(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        stream.submitVideo(buffer, orientation: orientation)
    }

    public func handleAudio(_ sample: CMSampleBuffer) {
        guard let pcm = AudioSamples.pcmBuffer(from: sample) else { return }
        stream.submitAudio(pcm, hostTime: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
    }

    /// Stops streaming and returns the TV to its home screen.
    public func stop() {
        let first: Bool = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        logInfo("broadcast stopping")
        Log.shared.sink = nil
        stream.stop()
        let done = DispatchSemaphore(value: 0)
        Task {
            await self.cast.stopApp()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        cast.close()
        webSocket.stop()
        http.stop()
    }

    // MARK: - Setup

    private func run() async throws {
        logInfo("broadcast starting")
        let webSocketPort = try await webSocket.start(preferredPort: 8765)
        let httpPort = try await http.start(preferredPort: 8080)
        stream.startClock()

        guard let device = await ChromecastBrowser.first(timeout: 10) else {
            throw MirrorError("No Chromecast found. Check the phone is on the same Wi-Fi as the TV, and that CastMirror is allowed under Settings > Privacy & Security > Local Network.")
        }
        logInfo("found \(device.name)")
        try await cast.connect(to: device.endpoint)
        guard let address = cast.localAddress else {
            throw MirrorError("Couldn't find this phone's Wi-Fi address.")
        }
        try await cast.launch(appId: DashCast.appId, waitingFor: DashCast.namespace, restart: true)
        // No debug time keeps the stats up the whole time; 0 hides them.
        let page = DashCast.receiverPageURL(base: "http://\(address):\(httpPort)/receiver/",
                                            webSocket: "ws://\(address):\(webSocketPort)",
                                            debugSeconds: statsShown() ? nil : 0)
        cast.sendToApp(namespace: DashCast.namespace, DashCast.loadMessage(url: page))
        logInfo("opening \(page) on \(device.name)")
    }

    private func statsShown() -> Bool {
        lock.withLock { showStats }
    }

    private func fail(_ message: String) {
        // Off the calling queue: stop() waits on the Cast client's queue.
        DispatchQueue.global().async {
            guard !self.lock.withLock({ self.stopped }) else { return }
            logInfo("error: \(message)")
            self.stop()
            self.onFatalError?(message)
        }
    }

    // MARK: - Receiver

    private func receiverConnected() {
        let show: Bool = lock.withLock {
            waitingForKeyframe = true
            keyframeRequested = true
            return showStats
        }
        // In case the setting changed after the page was opened.
        sendJSON(["type": "overlay", "show": show])
        if let segment = stream.currentInitSegment { webSocket.send(segment) }
        stream.requestKeyframe()
    }

    private func send(_ chunk: MirrorStream.Chunk) {
        switch chunk {
        case .initSegment(let data):
            webSocket.send(data)
        case .audio(let data):
            webSocket.send(data)
        case .video(let data, let keyframe):
            let backlog = webSocket.backlog
            let (drop, askForKeyframe): (Bool, Bool) = lock.withLock {
                if backlog > backlogLimit {
                    waitingForKeyframe = true
                    keyframeRequested = false
                    dropped += 1
                    return (true, false)
                }
                if waitingForKeyframe && !keyframe {
                    // The backlog has cleared; ask for a keyframe to start again from.
                    let ask = !keyframeRequested
                    keyframeRequested = true
                    dropped += 1
                    return (true, ask)
                }
                waitingForKeyframe = false
                return (false, false)
            }
            if askForKeyframe { stream.requestKeyframe() }
            if !drop { webSocket.send(data) }
        }
    }

    private func receiverMessage(_ text: String) {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
        case "ping":
            if let t = message["t"] { sendJSON(["type": "pong", "t": t]) }
        case "log":
            Log.shared.info("tv: \(message["msg"] ?? "")", forward: false)
        case "stats":
            guard let s = message["stats"] as? [String: Any] else { return }
            let dropped = lock.withLock { self.dropped }
            Log.shared.info("tv: \(s["res"] ?? "?") @ \(s["fps"] ?? "?") fps, plays \(s["play"] ?? "?")x, "
                + "buffer \(s["lagMs"] ?? "?") ms, rtt \(s["rttMs"] ?? "?") ms, \(s["mbps"] ?? "?") Mbps, "
                + "jumps \(s["jumps"] ?? "?"), stalls \(s["stalls"] ?? "?"), phone dropped \(dropped)", forward: false)
        default:
            break
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        webSocket.send(data, text: true)
    }
}
