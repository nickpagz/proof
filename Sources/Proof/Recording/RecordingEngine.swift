import AVFoundation
import ScreenCaptureKit
import VideoToolbox

/// What a recording shows. Rectangles are in global CoreGraphics points.
enum RecordingSource {
    case area(CGRect)
    case window(PickableWindow)
    case display(CGDirectDisplayID)

    var frame: CGRect {
        switch self {
        case .area(let rect): return rect
        case .window(let window): return window.frame
        case .display(let id): return CGDisplayBounds(id)
        }
    }

    var kind: CaptureKind {
        switch self {
        case .area: return .area
        case .window: return .window
        case .display: return .fullscreen
        }
    }

    var appName: String? {
        if case .window(let window) = self { return window.ownerName }
        return nil
    }
}

enum RecordingError: LocalizedError {
    case cannotAddInput(String)
    case writerFailed(String)
    case notPrepared
    case noVideoTrack
    case mixdownFailed(String)
    case insufficientDiskSpace
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotAddInput(let name): return "Could not set up the \(name) track."
        case .writerFailed(let detail): return "Writing the recording failed (\(detail))."
        case .notPrepared: return "The recording was not set up."
        case .noVideoTrack: return "The recording contains no video."
        case .mixdownFailed(let detail): return "Finishing the recording failed (\(detail))."
        case .insufficientDiskSpace: return "Not enough free disk space to record (Proof needs at least 1 GB)."
        case .exportFailed(let detail): return "Couldn't make the file (\(detail))."
        }
    }

    /// Recording writes several hundred MB in a long session; refuse to start below this.
    static let minimumFreeBytes: Int64 = 1_000_000_000

    static func hasEnoughDiskSpace() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let free = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else {
            return true
        }
        return free >= minimumFreeBytes
    }
}

/// Everything the stream needs, worked out once from the source and the settings.
struct RecordingConfig {
    let filter: SCContentFilter
    /// The recorded part of the display, in display-local points; nil records the whole filter.
    let sourceRect: CGRect?
    let isWindow: Bool
    let width: Int
    let height: Int
    let fps: Int
    let showsCursor: Bool
    let showsClicks: Bool
    let systemAudio: Bool
    let microphone: Bool
    /// nil follows the system's default input.
    let microphoneDeviceID: String?

    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    /// H.264 encoders top out around 4K; anything larger is scaled down to fit.
    static let maxSide: CGFloat = 3840

    /// Proof's own windows (the recording bar and border among them) must already be on screen,
    /// so they can be left out of the recording.
    static func make(source: RecordingSource, prefs: Preferences, systemAudio: Bool, microphone: Bool) async throws -> RecordingConfig {
        let content = try await ScreenGrabber.shareableContent()
        let filter: SCContentFilter
        var sourceRect: CGRect?
        let size: CGSize
        switch source {
        case .window(let picked):
            guard let window = content.windows.first(where: { $0.windowID == picked.id }) else { throw CaptureError.windowGone }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = filter.contentRect.size
        case .area, .display:
            guard let displayID = ScreenGeometry.displayID(containing: source.frame),
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
            let bounds = CGDisplayBounds(displayID)
            let local = source.frame.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY).integral
            guard local.width >= 2, local.height >= 2 else { throw CaptureError.emptyArea }
            filter = SCContentFilter(display: display, excludingWindows: excludedWindows(in: content, hideDesktopIcons: prefs.hideDesktopIcons))
            if case .area = source { sourceRect = local }
            size = local.size
        }
        let wanted: CGFloat = prefs.recordAtFullResolution ? CGFloat(filter.pointPixelScale) : 1
        let scale = min(wanted, maxSide / max(size.width, size.height, 1))
        func even(_ points: CGFloat) -> Int {
            let pixels = Int((points * scale).rounded(.down))
            return max(pixels - pixels % 2, 2)
        }
        return RecordingConfig(filter: filter, sourceRect: sourceRect, isWindow: source.kind == .window,
                               width: even(size.width), height: even(size.height), fps: prefs.recordingFrameRate,
                               showsCursor: prefs.showCursorInRecordings, showsClicks: prefs.highlightClicks,
                               systemAudio: systemAudio, microphone: microphone, microphoneDeviceID: prefs.microphoneDeviceID)
    }

    /// Every window of Proof's, and the desktop icons when captures hide them.
    private static func excludedWindows(in content: SCShareableContent, hideDesktopIcons: Bool) -> [SCWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            if app.processID == me { return true }
            return hideDesktopIcons && app.bundleIdentifier == "com.apple.finder" && window.windowLayer < 0
        }
    }

    func streamConfiguration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = width
        c.height = height
        if let sourceRect { c.sourceRect = sourceRect }
        c.scalesToFit = true
        c.preservesAspectRatio = true
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        c.queueDepth = 6
        c.showsCursor = showsCursor
        c.showMouseClicks = showsClicks
        c.captureResolution = .best
        c.pixelFormat = Self.pixelFormat
        c.colorSpaceName = CGColorSpace.sRGB
        if isWindow {
            c.ignoreShadowsSingleWindow = true
            c.includeChildWindows = true
            c.shouldBeOpaque = true
            c.backgroundColor = CGColor.black
        }
        c.capturesAudio = systemAudio
        c.excludesCurrentProcessAudio = true
        c.sampleRate = 48_000
        c.channelCount = 2
        c.captureMicrophone = microphone
        c.microphoneCaptureDeviceID = microphoneDeviceID
        return c
    }
}

/// Owns the SCStream and hands complete sample buffers to closures on `queue`.
final class ScreenCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "io.github.nickpagz.proof.recording")

    var onScreenFrame: ((CMSampleBuffer) -> Void)?
    var onSystemAudio: ((CMSampleBuffer) -> Void)?
    var onMicrophone: ((CMSampleBuffer) -> Void)?
    /// Called when the system ends the stream (display unplugged, window closed, error).
    var onStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private var receivedTypes = Set<SCStreamOutputType>()

    func start(config: RecordingConfig) async throws {
        let stream = SCStream(filter: config.filter, configuration: config.streamConfiguration(), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if config.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if config.microphone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
        Log.note("recording stream started \(config.width)x\(config.height)@\(config.fps) window=\(config.isWindow) systemAudio=\(config.systemAudio) mic=\(config.microphone) micDevice=\(config.microphoneDeviceID ?? "default")")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            Log.note("stopCapture: \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if !receivedTypes.contains(type) {
            receivedTypes.insert(type)
            Log.note("first recording buffer of type \(type.rawValue) (0=screen 1=system audio 2=mic)")
        }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer), CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            onScreenFrame?(sampleBuffer)
        case .audio:
            onSystemAudio?(sampleBuffer)
        case .microphone:
            onMicrophone?(sampleBuffer)
        @unknown default:
            break
        }
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return false
        }
        return status == .complete
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.note("recording stream stopped by the system: \(error.localizedDescription)")
        self.stream = nil
        onStopped?(error)
    }
}

/// Fixed-rate tick on the capture queue, which keeps the video track alive through still stretches.
final class FramePacer {
    private let timer: DispatchSourceTimer

    init(queue: DispatchQueue, fps: Int, tick: @escaping () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000 / max(fps, 1)))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler(handler: tick)
    }

    func start() { timer.resume() }

    func stop() { timer.cancel() }
}

/// H.264 and AAC, which every browser, chat app and VideoPress plays.
enum CodecSettings {
    /// Screen content compresses well; 0.05 bits per pixel per frame keeps text sharp.
    static func videoBitrate(width: Int, height: Int, fps: Int) -> Int {
        max(1_000_000, Int(Double(width * height * fps) * 0.05))
    }

    static func video(width: Int, height: Int, fps: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate(width: width, height: height, fps: fps),
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    static func audio(channels: Int, sampleRate: Double = 48_000, bitrate: Int = 160_000) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate,
        ]
        if channels == 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return settings
    }

    static func pcmStereo(sampleRate: Double = 48_000) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }
}
