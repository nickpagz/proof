import AVFoundation
import AppKit
import Observation
import SwiftUI

/// A finished recording, before it is saved anywhere.
struct RecordedVideo {
    /// The .mp4 in the drafts folder, named like a capture.
    let url: URL
    let pixelSize: CGSize
    let duration: TimeInterval
    let kind: CaptureKind
    let appName: String?
    let date: Date
    let title: String
}

struct Microphone: Identifiable, Hashable {
    let id: String
    let name: String

    static func all() -> [Microphone] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// Runs a recording from the chosen area to the finished file: the bar with the audio switches
/// and Record, the countdown, the border while recording, and Stop.
@MainActor @Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        /// The bar is up, waiting for Record.
        case ready
        case starting
        case recording(since: Date)
        case finishing
    }

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhaseChange?() } }
    }
    /// A note on the bar, such as a microphone Proof may not use.
    private(set) var message: String?
    private(set) var microphones: [Microphone] = []

    var isActive: Bool { phase != .idle }
    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    @ObservationIgnored weak var state: AppState?
    @ObservationIgnored var onFinished: ((RecordedVideo) -> Void)?
    @ObservationIgnored var onPhaseChange: (() -> Void)?

    @ObservationIgnored private var source: RecordingSource?
    @ObservationIgnored private var title = ""
    @ObservationIgnored private var date = Date()
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var bar: RecordingBarPanel?
    @ObservationIgnored private var border: RecordingBorderPanel?

    /// Puts the bar and border up around `source`; nothing records until Record.
    func begin(_ source: RecordingSource, title: String) {
        guard phase == .idle, let state else { return }
        self.source = source
        self.title = title
        date = Date()
        message = nil
        microphones = Microphone.all()
        let border = RecordingBorderPanel(around: source)
        border.orderFrontRegardless()
        self.border = border
        let bar = RecordingBarPanel(state: state, below: source.frame)
        bar.orderFrontRegardless()
        bar.makeKey()
        self.bar = bar
        phase = .ready
    }

    /// The shortcut and the menu bar item: Record when the bar is waiting, Stop while recording.
    func primaryAction() {
        switch phase {
        case .ready: Task { await record() }
        case .recording: Task { await stop() }
        default: break
        }
    }

    func record() async {
        guard phase == .ready, let source, let state else { return }
        phase = .starting
        guard RecordingError.hasEnoughDiskSpace() else {
            await fail(RecordingError.insufficientDiskSpace)
            return
        }
        let microphone = await microphoneAllowed(state.prefs.recordMicrophone)
        do {
            // The bar and border are on screen now, so the filter leaves them out.
            let config = try await RecordingConfig.make(source: source, prefs: state.prefs,
                                                        systemAudio: state.prefs.recordSystemAudio, microphone: microphone)
            let session = RecordingSession()
            session.onStreamStopped = { [weak self] error in
                Task { @MainActor in await self?.streamStopped(error) }
            }
            self.session = session
            try await session.prepare(config)
            if state.prefs.recordingCountdown {
                guard await CountdownHUD.run(seconds: 3), phase == .starting else {
                    await cancel()
                    return
                }
            }
            let folder = AppInfo.draftsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.folder = folder
            try await session.beginRecording(tempURL: folder.appendingPathComponent(title).appendingPathExtension("mov"))
            phase = .recording(since: Date())
            border?.isRecording = true
        } catch {
            await fail(error)
        }
    }

    /// Finishes the file and hands it on.
    func stop() async {
        guard isRecording, let session, let source else { return }
        phase = .finishing
        do {
            let summary = try await session.stop()
            let info = await VideoExport.info(summary.url)
            let video = RecordedVideo(url: summary.url, pixelSize: info?.size ?? .zero, duration: info?.duration ?? summary.duration,
                                      kind: source.kind, appName: source.appName, date: date, title: title)
            Log.note("recorded \(source.kind.rawValue) \(Int(video.pixelSize.width))x\(Int(video.pixelSize.height)) \(String(format: "%.1f", video.duration)) s")
            close()
            onFinished?(video)
        } catch {
            await fail(error)
        }
    }

    /// Cancel before recording, or Discard during it: nothing is kept.
    func cancel() async {
        let session = self.session
        let folder = self.folder
        close()
        await session?.cancel()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// "0:42", or "1:02:03" past an hour.
    nonisolated static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    func setMicrophone(_ id: String?) {
        state?.prefs.microphoneDeviceID = id
        state?.prefs.recordMicrophone = true
    }

    private func microphoneAllowed(_ wanted: Bool) async -> Bool {
        guard wanted else { return false }
        switch Permissions.state(for: .audio) {
        case .granted:
            return true
        case .notDetermined:
            if await Permissions.request(.audio) { return true }
        case .denied:
            break
        }
        message = "Proof may not use the microphone, so this recording has no voice. Allow it in System Settings → Privacy & Security → Microphone."
        return false
    }

    private func streamStopped(_ error: Error) async {
        Log.note("recording stream ended early: \(error.localizedDescription)")
        if isRecording {
            // Keep what was recorded, as if Stop was pressed.
            await stop()
        } else {
            await fail(error)
        }
    }

    private func fail(_ error: Error) async {
        Log.note("recording failed: \(error.localizedDescription)")
        await cancel()
        if case CaptureError.permissionDenied = error {
            Permissions.requestScreenRecording()
        }
        Notifier.shared.notify(title: "Recording failed", body: error.localizedDescription)
    }

    private func close() {
        bar?.orderOut(nil)
        border?.orderOut(nil)
        bar = nil
        border = nil
        session = nil
        folder = nil
        source = nil
        message = nil
        phase = .idle
    }
}

// MARK: - Bar

/// Floats under the area being recorded. Proof's windows are left out of recordings, so it can
/// sit anywhere, and it can be dragged out of the way.
private final class RecordingBarPanel: NSPanel, CaptureChrome {
    init(state: AppState, below frame: CGRect) {
        let size = NSSize(width: 520, height: 96)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: RecordingBar(state: state, recorder: state.recorder))
        setFrameOrigin(Self.origin(for: size, below: frame))
    }

    override var canBecomeKey: Bool { true }

    /// Under the area if there's room, else above it, else inside along its bottom edge.
    private static func origin(for size: NSSize, below frame: CGRect) -> NSPoint {
        let area = ScreenGeometry.cocoaRect(fromGlobal: frame)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: area.midX, y: area.midY)) } ?? ScreenGeometry.screenUnderMouse
        let visible = screen.visibleFrame
        var y = area.minY - 8 - size.height
        if y < visible.minY {
            y = area.maxY + 8
            if y + size.height > visible.maxY { y = max(area.minY, visible.minY) + 16 }
        }
        let x = min(max(area.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        return NSPoint(x: x, y: y)
    }
}

private struct RecordingBar: View {
    @Bindable var state: AppState
    let recorder: RecordingController

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                switch recorder.phase {
                case .ready, .starting:
                    microphoneControl
                    systemAudioControl
                    Divider().frame(height: 22)
                    Button {
                        Task { await recorder.record() }
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
                    .disabled(recorder.phase == .starting)
                    Button("Cancel") { Task { await recorder.cancel() } }
                        .keyboardShortcut(.cancelAction)
                case .recording(let since):
                    Circle().fill(.red).frame(width: 10, height: 10)
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(RecordingController.elapsedLabel(context.date.timeIntervalSince(since)))
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .frame(minWidth: 52, alignment: .leading)
                    }
                    Button {
                        Task { await recorder.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    Button {
                        Task { await recorder.cancel() }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Discard this recording")
                case .finishing:
                    ProgressView().controlSize(.small)
                    Text("Finishing…")
                case .idle:
                    EmptyView()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            if let message = recorder.message {
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 480)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// Click switches the microphone on or off; the arrow picks which one.
    private var microphoneControl: some View {
        let on = state.prefs.recordMicrophone
        return Menu {
            Button {
                recorder.setMicrophone(nil)
            } label: {
                Text("System Default\(state.prefs.microphoneDeviceID == nil ? "  ✓" : "")")
            }
            Divider()
            ForEach(recorder.microphones) { mic in
                Button {
                    recorder.setMicrophone(mic.id)
                } label: {
                    Text("\(mic.name)\(state.prefs.microphoneDeviceID == mic.id ? "  ✓" : "")")
                }
            }
            Divider()
            Button("No Microphone") { state.prefs.recordMicrophone = false }
        } label: {
            Label(on ? microphoneName : "No mic", systemImage: on ? "mic.fill" : "mic.slash")
        } primaryAction: {
            state.prefs.recordMicrophone.toggle()
        }
        .menuStyle(.button)
        .fixedSize()
        .help(on ? "Recording the microphone. Click to turn it off; the arrow picks a microphone." : "Click to record the microphone")
    }

    private var microphoneName: String {
        guard let id = state.prefs.microphoneDeviceID else { return "Microphone" }
        return recorder.microphones.first { $0.id == id }?.name ?? "Microphone"
    }

    private var systemAudioControl: some View {
        let on = state.prefs.recordSystemAudio
        return Button {
            state.prefs.recordSystemAudio.toggle()
        } label: {
            Label("Computer audio", systemImage: on ? "speaker.wave.2.fill" : "speaker.slash")
        }
        .help(on ? "Recording sound from your apps. Click to turn it off." : "Click to record sound from your apps")
    }
}

// MARK: - Border

/// A line just outside the recorded area (inside the screen edge for a whole display): dashed
/// white while waiting, red while recording. Clicks pass through it.
private final class RecordingBorderPanel: NSPanel, CaptureChrome {
    var isRecording = false { didSet { contentView?.needsDisplay = true } }

    init(around source: RecordingSource) {
        let inset: CGFloat = source.kind == .fullscreen ? 0 : -3
        let frame = ScreenGeometry.cocoaRect(fromGlobal: source.frame).insetBy(dx: inset, dy: inset)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(frame, display: false)
        contentView = BorderView(panel: self)
    }
}

private final class BorderView: NSView {
    private unowned let panel: RecordingBorderPanel

    init(panel: RecordingBorderPanel) {
        self.panel = panel
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        if panel.isRecording {
            NSColor.systemRed.setStroke()
        } else {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.setLineDash([8, 6], count: 2, phase: 0)
        }
        path.stroke()
    }
}
