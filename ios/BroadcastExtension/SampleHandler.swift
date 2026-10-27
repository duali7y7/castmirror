import CastMirrorCore
import CoreMedia
import ImageIO
import ReplayKit

/// The broadcast upload extension iOS starts when you pick CastMirror under
/// Screen Recording. Everything except ReplayKit lives in CastMirrorCore.
final class SampleHandler: RPBroadcastSampleHandler {
    private var session: MirrorSession?
    private var settings: OptionsChannel.Observation?
    private let settingsQueue = DispatchQueue(label: "castmirror.settings")

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // The extension can't read the app's settings, so it starts with the
        // last ones the app sent and listens for more.
        let defaults = UserDefaults.standard
        var options = MirrorOptions(defaults: defaults)
        // The receiver page is bundled with the extension and served to the TV from here.
        let session = MirrorSession(receiverDirectory: Bundle.main.url(forResource: "receiver", withExtension: nil),
                                    options: options)
        session.onFatalError = { [weak self] message in
            let error = NSError(domain: "CastMirror", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            self?.finishBroadcastWithError(error)
        }
        self.session = session
        settings = OptionsChannel.observe(queue: settingsQueue, showStats: { [weak session] show in
            options.showStats = show
            options.save(to: defaults)
            session?.setShowStats(show)
        }, sound: { [weak session] sound in
            options.sound = sound
            options.save(to: defaults)
            session?.setSound(sound)
        })
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
        guard let session else { return }
        switch sampleBufferType {
        case .video:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            var orientation = CGImagePropertyOrientation.up
            if let raw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
               let value = CGImagePropertyOrientation(rawValue: raw.uint32Value) {
                orientation = value
            }
            session.handleVideo(pixelBuffer, orientation: orientation)
        case .audioApp:
            session.handleAudio(sampleBuffer)  // ignored while the sound stays on the phone
        default:
            break  // the microphone isn't used
        }
    }
}
