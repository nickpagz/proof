import AVFoundation
import CoreMedia

/// One recording: warm-up, the writer session from T0, pacing, stop, and the mixdown to .mp4.
/// Adapted from Loominate's, without the camera bubble.
final class RecordingSession {
    enum State { case idle, warmingUp, recording, stopping, finished }

    struct Summary {
        let url: URL
        let duration: TimeInterval
    }

    private let capture = ScreenCaptureSession()
    private var queue: DispatchQueue { capture.queue }

    private var config: RecordingConfig?
    private var writer: RecordingWriter?
    private var pacer: FramePacer?
    private var tempURL: URL?

    // Capture-queue state.
    private var state: State = .idle
    private var latestScreen: CMSampleBuffer?
    private var lastAppended: CVPixelBuffer?
    private var lastAppendedPTS: CMTime = .invalid
    private var startTime: CMTime?
    private var systemAudioFormat: CMFormatDescription?
    private var microphoneFormat: CMFormatDescription?

    /// Fired on an arbitrary queue when the system ends the stream mid-recording.
    var onStreamStopped: ((Error) -> Void)?

    /// Starts the stream so audio formats and a first frame arrive before T0.
    func prepare(_ config: RecordingConfig) async throws {
        self.config = config
        capture.onScreenFrame = { [weak self] buffer in self?.handleScreen(buffer) }
        capture.onSystemAudio = { [weak self] buffer in self?.handleAudio(buffer, track: .systemAudio) }
        capture.onMicrophone = { [weak self] buffer in self?.handleAudio(buffer, track: .microphone) }
        capture.onStopped = { [weak self] error in
            guard let self else { return }
            let wasRunning = self.queue.sync { self.state == .recording || self.state == .warmingUp }
            if wasRunning { self.onStreamStopped?(error) }
        }
        queue.sync { state = .warmingUp }
        try await capture.start(config: config)
    }

    /// Starts writing at the current host time. Call after the countdown.
    func beginRecording(tempURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.beginOnQueue(tempURL: tempURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func beginOnQueue(tempURL: URL) throws {
        guard let config, state == .warmingUp else { throw RecordingError.notPrepared }
        let t0 = CMClockGetTime(CMClockGetHostTimeClock())
        let writer = try RecordingWriter(url: tempURL,
                                         width: config.width,
                                         height: config.height,
                                         videoSettings: CodecSettings.video(width: config.width, height: config.height, fps: config.fps),
                                         wantsSystemAudio: config.systemAudio,
                                         systemAudioFormat: systemAudioFormat,
                                         wantsMicrophone: config.microphone,
                                         microphoneFormat: microphoneFormat)
        try writer.start(at: t0)
        self.writer = writer
        self.tempURL = tempURL
        startTime = t0
        state = .recording
        Log.note("recording started; audio formats known: system=\(systemAudioFormat != nil) mic=\(microphoneFormat != nil)")

        // Put the frame we already have at T0 so a still screen doesn't start black.
        if let buffer = latestScreen, let pixels = CMSampleBufferGetImageBuffer(buffer) {
            appendFrame(pixels, at: t0)
        }
        let pacer = FramePacer(queue: queue, fps: config.fps) { [weak self] in self?.tick() }
        self.pacer = pacer
        pacer.start()
    }

    /// Ends capture, finishes the intermediate .mov and produces the .mp4 next to it.
    func stop() async throws -> Summary {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.state = .stopping
                self.pacer?.stop()
                self.pacer = nil
                continuation.resume()
            }
        }
        await capture.stop()
        queue.sync {}   // drain any callback already in flight

        guard let writer, let tempURL, let startTime else { throw RecordingError.notPrepared }
        let duration = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), startTime).seconds
        try await writer.finish()

        let finalURL = tempURL.deletingPathExtension().appendingPathExtension("mp4")
        let gains: [Float] = writer.audioTrackOrder.map { $0 == .microphone ? 1.0 : 0.8 }
        try await Mixdown.run(input: tempURL, output: finalURL, gains: gains)
        try? FileManager.default.removeItem(at: tempURL)

        queue.sync { state = .finished }
        latestScreen = nil
        lastAppended = nil
        return Summary(url: finalURL, duration: duration)
    }

    /// Stops everything and keeps nothing.
    func cancel() async {
        queue.sync {
            state = .idle
            pacer?.stop()
            pacer = nil
        }
        await capture.stop()
        queue.sync {}
        writer?.cancel()
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        writer = nil
    }

    // MARK: Capture-queue handlers

    private func handleScreen(_ buffer: CMSampleBuffer) {
        latestScreen = buffer
        guard state == .recording, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        appendFrame(pixels, at: CMSampleBufferGetPresentationTimeStamp(buffer))
    }

    private func handleAudio(_ buffer: CMSampleBuffer, track: RecordingWriter.Track) {
        if track == .systemAudio, systemAudioFormat == nil {
            systemAudioFormat = CMSampleBufferGetFormatDescription(buffer)
        } else if track == .microphone, microphoneFormat == nil {
            microphoneFormat = CMSampleBufferGetFormatDescription(buffer)
        }
        guard state == .recording else { return }
        writer?.appendAudio(buffer, track: track)
    }

    private func appendFrame(_ pixels: CVPixelBuffer, at pts: CMTime) {
        if writer?.appendVideo(pixels, at: pts) == true {
            lastAppended = pixels
            lastAppendedPTS = pts
        }
    }

    /// ScreenCaptureKit sends no frames while nothing changes; repeat the last one each second so
    /// the video track covers the whole recording.
    private func tick() {
        guard state == .recording else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if lastAppendedPTS.isValid, let last = lastAppended, CMTimeSubtract(now, lastAppendedPTS).seconds >= 1.0,
           writer?.appendVideo(last, at: now) == true {
            lastAppendedPTS = now
        }
    }
}

/// AVAssetWriter for the intermediate .mov: video plus up to two audio tracks.
/// Everything but `finish` runs on the capture queue.
final class RecordingWriter {
    enum Track: Hashable {
        case video, systemAudio, microphone
    }

    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioInputs: [Track: AVAssetWriterInput] = [:]
    private var lastPTS: [Track: CMTime] = [:]
    private(set) var appended: [Track: Int] = [:]
    private(set) var dropped: [Track: Int] = [:]
    private var sessionStart: CMTime?
    /// Audio tracks in the order they were added, which the mixdown gains follow.
    private(set) var audioTrackOrder: [Track] = []

    init(url: URL, width: Int, height: Int, videoSettings: [String: Any],
         wantsSystemAudio: Bool, systemAudioFormat: CMFormatDescription?,
         wantsMicrophone: Bool, microphoneFormat: CMFormatDescription?) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Fragments keep what was recorded readable if Proof stops abruptly.
        writer.movieFragmentInterval = CMTime(seconds: 3, preferredTimescale: 600)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: RecordingConfig.pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(videoInput) else { throw RecordingError.cannotAddInput("video") }
        writer.add(videoInput)

        if wantsSystemAudio {
            audioInputs[.systemAudio] = try Self.makeAudioInput(format: systemAudioFormat, fallbackChannels: 2, writer: writer, name: "computer audio")
            audioTrackOrder.append(.systemAudio)
        }
        if wantsMicrophone {
            audioInputs[.microphone] = try Self.makeAudioInput(format: microphoneFormat, fallbackChannels: 1, writer: writer, name: "microphone")
            audioTrackOrder.append(.microphone)
        }
    }

    private static func makeAudioInput(format: CMFormatDescription?, fallbackChannels: Int, writer: AVAssetWriter, name: String) throws -> AVAssetWriterInput {
        var channels = fallbackChannels
        if let asbd = format?.audioStreamBasicDescription { channels = Int(asbd.mChannelsPerFrame) }
        channels = min(max(channels, 1), 2)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: CodecSettings.audio(channels: channels), sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.cannotAddInput(name) }
        writer.add(input)
        return input
    }

    func start(at time: CMTime) throws {
        guard writer.startWriting() else { throw writer.error ?? RecordingError.writerFailed("could not start writing") }
        writer.startSession(atSourceTime: time)
        sessionStart = time
    }

    @discardableResult
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at pts: CMTime) -> Bool {
        guard let start = sessionStart, writer.status == .writing, pts >= start else { return false }
        if let last = lastPTS[.video], pts <= last { dropped[.video, default: 0] += 1; return false }
        guard videoInput.isReadyForMoreMediaData, adaptor.append(pixelBuffer, withPresentationTime: pts) else {
            dropped[.video, default: 0] += 1
            return false
        }
        lastPTS[.video] = pts
        appended[.video, default: 0] += 1
        return true
    }

    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer, track: Track) -> Bool {
        guard let input = audioInputs[track], let start = sessionStart, writer.status == .writing else { return false }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts >= start else { return false }
        if let last = lastPTS[track], pts <= last { dropped[track, default: 0] += 1; return false }
        guard input.isReadyForMoreMediaData, input.append(sampleBuffer) else {
            dropped[track, default: 0] += 1
            return false
        }
        lastPTS[track] = pts
        appended[track, default: 0] += 1
        return true
    }

    func finish() async throws {
        if writer.status == .writing {
            videoInput.markAsFinished()
            for input in audioInputs.values { input.markAsFinished() }
            await writer.finishWriting()
        }
        Log.note("recording writer finished: appended=\(appended) dropped=\(dropped) status=\(writer.status.rawValue)")
        guard writer.status == .completed else {
            throw writer.error ?? RecordingError.writerFailed("status \(writer.status.rawValue)")
        }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
    }
}

/// Turns the intermediate .mov (video plus up to two audio tracks) into an .mp4 with exactly one
/// audio track; players, VideoPress among them, play only the first. Video passes through untouched.
enum Mixdown {
    /// `gains` apply by audio track index when there is more than one track.
    static func run(input: URL, output: URL, gains: [Float]) async throws {
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw RecordingError.noVideoTrack }

        var audioTracks: [AVAssetTrack] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let range = try await track.load(.timeRange)
            if range.duration.seconds > 0 { audioTracks.append(track) }
        }
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw RecordingError.mixdownFailed("cannot read video") }
        reader.add(videoOutput)
        let videoFormat = try await videoTrack.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw RecordingError.mixdownFailed("cannot write video") }
        writer.add(videoInput)

        // One track passes through; several are decoded, mixed and encoded again.
        var audioPair: (AVAssetReaderOutput, AVAssetWriterInput)?
        if audioTracks.count == 1 {
            let track = audioTracks[0]
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            let format = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(out), writer.canAdd(input) else { throw RecordingError.mixdownFailed("cannot pass audio through") }
            reader.add(out)
            writer.add(input)
            audioPair = (out, input)
        } else if audioTracks.count > 1 {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: CodecSettings.pcmStereo())
            out.alwaysCopiesSampleData = false
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.enumerated().map { index, track in
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(index < gains.count ? gains[index] : 1, at: .zero)
                return params
            }
            out.audioMix = mix
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: CodecSettings.audio(channels: 2))
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(out), writer.canAdd(input) else { throw RecordingError.mixdownFailed("cannot mix audio") }
            reader.add(out)
            writer.add(input)
            audioPair = (out, input)
        }

        guard reader.startReading() else { throw reader.error ?? RecordingError.mixdownFailed("reader did not start") }
        guard writer.startWriting() else { throw writer.error ?? RecordingError.mixdownFailed("writer did not start") }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "io.github.nickpagz.proof.mixdown")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(from: videoOutput, to: videoInput, on: queue) }
            if let (out, input) = audioPair {
                group.addTask { await pump(from: out, to: input, on: queue) }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? RecordingError.mixdownFailed("reader failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? RecordingError.mixdownFailed("writer status \(writer.status.rawValue)")
        }
        Log.note("mixdown wrote \(output.lastPathComponent) from \(audioTracks.count) audio track(s)")
    }

    private static func pump(from output: AVAssetReaderOutput, to input: AVAssetWriterInput, on queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
