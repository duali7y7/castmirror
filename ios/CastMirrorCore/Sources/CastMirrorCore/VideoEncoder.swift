import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

/// Turns screen frames into H.264 the 2015 Chromecast can decode: turned
/// upright, scaled to fit 1920x1080, High profile level 4.1, no B-frames.
/// The output size follows the content, so rotating the phone starts a new
/// encoder (and a new init segment).
final class VideoEncoder {
    struct Settings {
        var maxWidth = 1920
        var maxHeight = 1080
        var fps = 30
        var bitrate = 6_000_000
        var keyframeInterval = 60
    }

    struct Frame {
        /// Length-prefixed NAL units, as MP4 stores them.
        let data: Data
        let isKeyframe: Bool
        /// Frame number at `Settings.fps`.
        let index: Int64
        let config: VideoTrackConfig
    }

    enum Turn {
        case none, clockwise, counterclockwise, upsideDown

        var isQuarter: Bool { self == .clockwise || self == .counterclockwise }
    }

    struct Geometry: Equatable {
        let sourceWidth: Int
        let sourceHeight: Int
        let turn: Turn
        /// Output size, after turning and scaling.
        let width: Int
        let height: Int
    }

    /// Called on a VideoToolbox thread.
    var onFrame: ((Frame) -> Void)?

    let settings: Settings
    private var transfer: VTPixelTransferSession?
    private var rotation: VTPixelRotationSession?
    private var scaledPool: CVPixelBufferPool?
    private var turnedPool: CVPixelBufferPool?
    private var compression: VTCompressionSession?
    private var geometry: Geometry?
    private var forceKeyframe = false
    private var reportedFailure = false

    init(settings: Settings) {
        self.settings = settings
    }

    deinit {
        invalidate()
    }

    /// How ReplayKit's orientation attachment says to turn the frame. On the
    /// iPhone it's the opposite of the EXIF reading of
    /// CGImagePropertyOrientation: turning .right (6) clockwise showed
    /// landscape upside down on the TV, so .right turns counterclockwise and
    /// .left (8) clockwise.
    static func turn(for orientation: CGImagePropertyOrientation) -> Turn {
        switch orientation {
        case .right, .rightMirrored: return .counterclockwise
        case .left, .leftMirrored: return .clockwise
        case .down, .downMirrored: return .upsideDown
        default: return .none
        }
    }

    func outputGeometry(width: Int, height: Int, orientation: CGImagePropertyOrientation) -> Geometry {
        let turn = Self.turn(for: orientation)
        let (shownWidth, shownHeight) = turn.isQuarter ? (height, width) : (width, height)
        let scale = min(1, Double(settings.maxWidth) / Double(shownWidth), Double(settings.maxHeight) / Double(shownHeight))
        func even(_ value: Double, max: Int) -> Int { Swift.max(2, Swift.min(max, Int((value / 2).rounded()) * 2)) }
        return Geometry(sourceWidth: width, sourceHeight: height, turn: turn,
                        width: even(Double(shownWidth) * scale, max: settings.maxWidth),
                        height: even(Double(shownHeight) * scale, max: settings.maxHeight))
    }

    /// Scales and turns a screen frame into a new buffer ready to encode.
    func prepare(_ source: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CVPixelBuffer? {
        let wanted = outputGeometry(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source), orientation: orientation)
        if wanted != geometry { rebuild(for: wanted) }
        guard let transfer, let scaledPool, let scaled = makeBuffer(scaledPool) else { return nil }
        var status = VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled)
        guard status == noErr else { return failed("scale", status) }
        if wanted.turn == .none { return scaled }
        guard let rotation, let turnedPool, let turned = makeBuffer(turnedPool) else { return nil }
        status = VTPixelRotationSessionRotateImage(rotation, scaled, turned)
        guard status == noErr else { return failed("rotate", status) }
        return turned
    }

    func encode(_ buffer: CVPixelBuffer, index: Int64) {
        guard let compression else { return }
        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            forceKeyframe = false
        }
        let rate = CMTimeScale(settings.fps)
        let status = VTCompressionSessionEncodeFrame(
            compression, imageBuffer: buffer,
            presentationTimeStamp: CMTime(value: index, timescale: rate),
            duration: CMTime(value: 1, timescale: rate),
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample else { return }
            self.output(sample)
        }
        if status != noErr { _ = failed("encode", status) }
    }

    /// Makes the next encoded frame a keyframe.
    func requestKeyframe() {
        forceKeyframe = true
    }

    /// Waits for every frame handed to the encoder to come out.
    func flush() {
        if let compression { VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid) }
    }

    func invalidate() {
        if let compression {
            VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compression)
        }
        compression = nil
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        transfer = nil
        if let rotation { VTPixelRotationSessionInvalidate(rotation) }
        rotation = nil
    }

    // MARK: - Setup

    private func rebuild(for wanted: Geometry) {
        logInfo("video: screen \(wanted.sourceWidth)x\(wanted.sourceHeight), turn \(wanted.turn), sending \(wanted.width)x\(wanted.height)")
        if transfer == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            if let session {
                // HD colors, and video range rather than the screen's full range.
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            }
            transfer = session
        }
        // Scale first, then turn, so the turn works on the smaller image.
        let (scaledWidth, scaledHeight) = wanted.turn.isQuarter ? (wanted.height, wanted.width) : (wanted.width, wanted.height)
        scaledPool = makePool(width: scaledWidth, height: scaledHeight)
        if wanted.turn != .none {
            if rotation == nil {
                var session: VTPixelRotationSession?
                VTPixelRotationSessionCreate(kCFAllocatorDefault, &session)
                rotation = session
            }
            let angle: CFString
            switch wanted.turn {
            case .clockwise: angle = kVTRotation_CW90
            case .counterclockwise: angle = kVTRotation_CCW90
            default: angle = kVTRotation_180
            }
            if let rotation { VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: angle) }
            turnedPool = makePool(width: wanted.width, height: wanted.height)
        } else {
            turnedPool = nil
        }
        if geometry?.width != wanted.width || geometry?.height != wanted.height {
            makeCompressionSession(width: wanted.width, height: wanted.height)
        }
        geometry = wanted
    }

    private func makeCompressionSession(width: Int, height: Int) {
        if let compression {
            VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compression)
        }
        compression = nil
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else {
            _ = failed("create encoder", status)
            return
        }
        let bytesPerSecond = settings.bitrate / 8
        let properties: [(CFString, AnyObject)] = [
            (kVTCompressionPropertyKey_RealTime, NSNumber(value: true)),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_4_1),
            // No B-frames, so every frame can be shown as soon as it arrives.
            (kVTCompressionPropertyKey_AllowFrameReordering, NSNumber(value: false)),
            // And no frame held back inside the encoder.
            (kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0)),
            (kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC),
            (kVTCompressionPropertyKey_AverageBitRate, settings.bitrate as NSNumber),
            // Short bursts up to 1.5x the average, then it must slow down.
            (kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bytesPerSecond * 3 / 2), NSNumber(value: 1)] as NSArray),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, settings.keyframeInterval as NSNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, Double(settings.keyframeInterval) / Double(settings.fps) as NSNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, settings.fps as NSNumber),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value)
            if result != noErr { logInfo("video: encoder ignored \(key) (\(result))") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        compression = session
    }

    private func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    private func makeBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    // MARK: - Output

    private func output(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard copied == noErr else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        guard let avcC = atoms?["avcC"] as? Data else { return }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        let index = Int64((CMSampleBufferGetPresentationTimeStamp(sample).seconds * Double(settings.fps)).rounded())
        onFrame?(Frame(data: data, isKeyframe: !notSync, index: index,
                       config: VideoTrackConfig(width: Int(size.width), height: Int(size.height), avcC: avcC)))
    }

    private func failed(_ step: String, _ status: OSStatus) -> CVPixelBuffer? {
        if !reportedFailure {
            reportedFailure = true
            logInfo("video: \(step) failed (\(status))")
        }
        return nil
    }
}
