import CastMirrorCore
import CoreMedia
import ImageIO
import ReplayKit

/// The broadcast upload extension iOS starts when you pick CastMirror under
/// Screen Recording. Everything except ReplayKit lives in CastMirrorCore.
final class SampleHandler: RPBroadcastSampleHandler {
    private var session: MirrorSession?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // The receiver page is bundled with the extension and served to the TV from here.
        let session = MirrorSession(receiverDirectory: Bundle.main.url(forResource: "receiver", withExtension: nil))
        session.onFatalError = { [weak self] message in
            let error = NSError(domain: "CastMirror", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            self?.finishBroadcastWithError(error)
        }
        self.session = session
        session.start()
    }

    override func broadcastFinished() {
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
            session.handleAudio(sampleBuffer)
        default:
            break  // the microphone isn't used
        }
    }
}
