import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Turns a finished recording into the file the recording window hands out: the .mp4 as it is,
/// a trimmed .mp4, or a GIF.
enum VideoExport {
    /// `range` of `url`, encoded again so the cut lands on the exact frame.
    static func trimmedMP4(from url: URL, range: CMTimeRange, to output: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingError.exportFailed("no exporter for this recording")
        }
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: .mp4)
    }

    /// The picture every 1/`fps` s, scaled to `maxWidth` pixels at most, looping forever.
    /// Recordings only have frames where the screen changed, so each GIF moment takes the latest
    /// frame before it, and a picture that holds becomes one longer GIF frame.
    static func gif(from url: URL, range: CMTimeRange?, maxWidth: Int?, fps: Int = 15, to output: URL,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecordingError.noVideoTrack }
        let duration = try await asset.load(.duration)
        let natural = try await track.load(.naturalSize)
        let span = range ?? CMTimeRange(start: .zero, duration: duration)
        let ticks = max(1, Int((span.duration.seconds * Double(fps)).rounded(.down)))

        let scale = maxWidth.map { min(1, CGFloat($0) / max(natural.width, 1)) } ?? 1
        let width = max(2, Int((natural.width * scale).rounded())), height = max(2, Int((natural.height * scale).rounded()))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = span
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        frames.alwaysCopiesSampleData = false
        reader.add(frames)
        guard reader.startReading() else { throw reader.error ?? RecordingError.exportFailed("can't read the recording") }

        try? FileManager.default.removeItem(at: output)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, ticks, nil) else {
            throw RecordingError.exportFailed("can't write a GIF there")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        var written = 0
        func add(_ image: CGImage, ticks held: Int) {
            let delay = Double(held) / Double(fps)
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay],
            ] as CFDictionary)
            written += 1
        }

        // `shown` is the picture on screen at the next tick; `held` counts ticks it has filled so far.
        var shown: CGImage?
        var held = 0
        var tick = 0
        func time(of tick: Int) -> Double { span.start.seconds + Double(tick) / Double(fps) }
        while tick < ticks, let sample = frames.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(sample), let image = cgImage(pixels) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // Ticks before this frame show the previous one.
            while tick < ticks, time(of: tick) < pts - 0.0001, shown != nil {
                held += 1
                tick += 1
            }
            if let previous = shown, held > 0 { add(previous, ticks: held) }
            shown = image
            held = 0
            progress(Double(tick) / Double(ticks))
        }
        // The last picture fills whatever is left.
        if let last = shown, tick < ticks { add(last, ticks: ticks - tick) }
        reader.cancelReading()
        guard written > 0 else { throw RecordingError.exportFailed("no frames could be read") }
        guard CGImageDestinationFinalize(destination) else { throw RecordingError.exportFailed("the GIF couldn't be finished") }
        progress(1)
        Log.note("gif wrote \(written) frames (\(ticks) ticks at \(fps) fps, \(width)x\(height)) to \(output.lastPathComponent)")
    }

    private static func cgImage(_ pixels: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        return image
    }

    /// Pixel size and length of a video file.
    static func info(_ url: URL) async -> (size: CGSize, duration: TimeInterval)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let duration = try? await asset.load(.duration) else { return nil }
        return (size, duration.seconds)
    }
}
