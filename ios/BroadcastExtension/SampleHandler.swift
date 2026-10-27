import CastMirrorCore
import CoreMedia
import ImageIO
import ReplayKit

/// The broadcast upload extension iOS starts when you pick CastMirror under
/// Screen Recording. Everything except ReplayKit lives in CastMirrorCore.
final class SampleHandler: RPBroadcastSampleHandler {
    private static let showStatsKey = "showStats"

    private var session: MirrorSession?
    private var settings: OptionsChannel.Observation?
    private let settingsQueue = DispatchQueue(label: "castmirror.settings")

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // The extension can't read the app's settings, so it starts with the
        // last ones the app sent and listens for more.
        let defaults = UserDefaults.standard
        // The receiver page is bundled with the extension and served to the TV from here.
        let session = MirrorSession(receiverDirectory: Bundle.main.url(forResource: "receiver", withExtension: nil),
                                    showStats: defaults.bool(forKey: Self.showStatsKey))
        session.onFatalError = { [weak self] message in
            let error = NSError(domain: "CastMirror", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            self?.finishBroadcastWithError(error)
        }
        self.session = session
        settings = OptionsChannel.observe(queue: settingsQueue) { [weak session] showStats in
            defaults.set(showStats, forKey: Self.showStatsKey)
            session?.setShowStats(showStats)
        }
        session.start()
        OptionsChannel.announceStarted()
    }

    override func broadcastFinished() {
        settings?.cancel()
        settings = nil
        session?.stop()
        session = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard let session, sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // App sound stays on the phone (see MirrorStream.Settings.includeAudio),
        // and the microphone isn't used.
        var orientation = CGImagePropertyOrientation.up
        if let raw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let value = CGImagePropertyOrientation(rawValue: raw.uint32Value) {
            orientation = value
        }
        session.handleVideo(pixelBuffer, orientation: orientation)
    }
}
