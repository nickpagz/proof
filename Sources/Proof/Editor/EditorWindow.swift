import AppKit
import SwiftUI

/// The annotation editor window: tools along the top, the canvas, and output actions along the bottom.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    private let canvas: CanvasView
    private let scrollView = NSScrollView()
    private var minimumWidth: CGFloat = 820

    init(model: EditorModel) {
        self.model = model
        canvas = CanvasView(model: model)
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = model.title
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.editor = model

        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.13, alpha: 1)
        scrollView.borderType = .noBorder

        let root = EditorRootView(model: model, canvas: scrollView)
        window.contentView = NSHostingView(rootView: root)
        // A narrower window would push the toolbar under the traffic lights and off the right edge.
        minimumWidth = max(820, NSHostingView(rootView: EditorToolbar(model: model)).fittingSize.width + 16)
        window.minSize = NSSize(width: minimumWidth, height: 440)

        model.onNeedsDisplay = { [weak self] in
            self?.canvas.syncSize()
        }
        model.onToolChange = { [weak self] in
            guard let self else { return }
            self.canvas.endTextEditing()
            self.canvas.syncSize()
            self.fitIfNeeded()
        }
        model.onZoomChange = { [weak self] in self?.applyZoom() }
        model.onRequestClose = { [weak self] in self?.window?.close() }
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewResized), name: NSView.frameDidChangeNotification, object: scrollView)
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(magnificationChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

        sizeWindowToFit()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
        DispatchQueue.main.async { self.fitIfNeeded() }
    }

    /// Starts big enough to show the capture at 100% when it fits on screen.
    private func sizeWindowToFit() {
        guard let window, let screen = NSScreen.main else { return }
        let size = canvas.layout.outputSize
        let chrome = CGSize(width: 80, height: 52 + 52 + 60)
        let maxSize = screen.visibleFrame.size
        let width = max(min(max(size.width + chrome.width, 900), maxSize.width * 0.9), minimumWidth)
        let height = min(max(size.height + chrome.height, 560), maxSize.height * 0.9)
        window.setContentSize(NSSize(width: width, height: height))
    }

    @objc private func scrollViewResized() { fitIfNeeded() }

    @objc private func magnificationChanged() {
        model.zoom = scrollView.magnification
    }

    private func fitIfNeeded() {
        guard model.zoom == nil else { return }
        let size = canvas.frame.size
        let available = scrollView.contentSize
        guard size.width > 0, size.height > 0, available.width > 0 else { return }
        let fit = min(1, (available.width - 48) / size.width, (available.height - 48) / size.height)
        scrollView.magnification = max(fit, scrollView.minMagnification)
    }

    private func applyZoom() {
        if let zoom = model.zoom {
            scrollView.magnification = zoom
        } else {
            fitIfNeeded()
        }
    }

    // MARK: Window delegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.confirmsUnsavedClose, model.hasUnhandledChanges else { return true }
        let alert = NSAlert()
        alert.messageText = model.needsSaveAs ? "Save this capture before closing?" : "Save your changes to “\(model.title)”?"
        alert.informativeText = "It hasn't been saved, copied or shared, so closing loses it."
        alert.addButton(withTitle: model.needsSaveAs ? "Save As…" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            if alert.suppressionButton?.state == .on { self.model.delegate?.editorStopAskingBeforeClose() }
            switch response {
            case .alertFirstButtonReturn:
                // Saving closes the window itself when that's on; otherwise close it here.
                self.model.save()
                if !self.model.hasUnhandledChanges && sender.isVisible { sender.close() }
            case .alertThirdButtonReturn:
                self.model.markHandled()
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        model.delegate?.editorDidClose(model)
    }
}

/// Routes menu commands (Save, Copy, Undo) to the editor.
final class EditorWindow: NSWindow {
    weak var editor: EditorModel?

    @objc func saveCapture(_ sender: Any?) { editor?.save() }
    @objc func saveCaptureAs(_ sender: Any?) { editor?.saveAs() }

    /// ⌘C on the canvas copies the whole result; a text field being edited keeps its own Copy.
    @objc func copy(_ sender: Any?) { editor?.copy() }

    @objc func delete(_ sender: Any?) { editor?.deleteSelection() }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(copy(_:)), firstResponder is NSTextView { return false }
        return super.responds(to: aSelector)
    }
}

// MARK: - SwiftUI chrome

private struct EditorRootView: View {
    @Bindable var model: EditorModel
    let canvas: NSScrollView

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model)
            Divider()
            CanvasHost(scrollView: canvas)
            Divider()
            EditorBottomBar(model: model)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minHeight: 440)
        .alert("Couldn't finish that", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(model.shareConfirmation.map { $0.copied ? "\($0.service) link copied" : "Shared to \($0.service)" } ?? "",
               isPresented: Binding(get: { model.shareConfirmation != nil }, set: { _ in })) {
            if let confirmation = model.shareConfirmation, !confirmation.copied {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(confirmation.url.absoluteString, forType: .string)
                    model.confirmShare()
                }
            }
            Button("OK") { model.confirmShare() }
                .keyboardShortcut(.defaultAction)
        } message: {
            if let confirmation = model.shareConfirmation {
                Text(confirmation.copied
                     ? "The link is on your clipboard, ready to paste:\n\(confirmation.url.absoluteString)"
                     : confirmation.url.absoluteString)
            }
        }
    }
}

private struct CanvasHost: NSViewRepresentable {
    let scrollView: NSScrollView
    func makeNSView(context: Context) -> NSScrollView { scrollView }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}

struct EditorToolbar: View {
    @Bindable var model: EditorModel

    private let drawingTools: [[EditorTool]] = [
        [.select],
        [.rectangle, .filledRectangle, .ellipse, .line, .arrow, .text],
        [.pixelate, .blur, .spotlight],
        [.counter, .pencil, .highlighter],
    ]

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64, height: 1)   // traffic lights
            group {
                toolButton(.crop)
                Button { model.showBackgroundPanel.toggle() } label: {
                    Image(systemName: "photo.on.rectangle.angled").frame(width: 30, height: 28)
                }
                .buttonStyle(ToolButtonStyle(active: model.document.background.enabled))
                .help("Background")
                .popover(isPresented: $model.showBackgroundPanel, arrowEdge: .bottom) {
                    BackgroundPanel(model: model)
                }
            }
            group {
                ForEach(Array(drawingTools.enumerated()), id: \.offset) { index, tools in
                    if index > 0 { Divider().frame(height: 20) }
                    ForEach(tools) { toolButton($0) }
                }
            }
            StyleControls(model: model)
            Spacer(minLength: 8)
            Menu {
                    Button("Save As…") { model.saveAs() }
                } label: {
                    Text(model.needsSaveAs ? "Save as…" : "Save")
                } primaryAction: {
                    model.save()
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .help(model.needsSaveAs ? "Choose a name and place (⌘S)" : "Save (⌘S)")
                .disabled(model.tool == .crop)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.bar)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
            .padding(3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        Button { model.tool = tool } label: {
            Image(systemName: tool.symbol).frame(width: 30, height: 28)
        }
        .buttonStyle(ToolButtonStyle(active: model.tool == tool))
        .help("\(tool.label)\(tool.key.map { " (\(String($0).uppercased()))" } ?? "")")
    }
}

private struct ToolButtonStyle: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.accentColor : (configuration.isPressed ? Color.primary.opacity(0.12) : Color.clear)))
            .contentShape(Rectangle())
    }
}

private struct StyleControls: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(RGBA.palette, id: \.self) { color in
                    Button { model.style.color = color } label: {
                        Label { Text(name(of: color)) } icon: { Image(nsImage: swatch(color)) }
                    }
                }
                Divider()
                Button("Custom Colour…") { ColorPanelBridge.shared.open(model: model) }
            } label: {
                Image(nsImage: swatch(model.style.color))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Colour")

            Menu {
                Section("Line width") {
                    ForEach([2, 4, 6, 10, 16] as [CGFloat], id: \.self) { width in
                        Button { model.style.lineWidth = width } label: {
                            Text("\(Int(width)) pt\(model.style.lineWidth == width ? "  ✓" : "")")
                        }
                    }
                }
                Section("Text size") {
                    ForEach([14, 20, 28, 40, 56] as [CGFloat], id: \.self) { size in
                        Button { model.style.fontSize = size } label: {
                            Text("\(Int(size)) pt\(model.style.fontSize == size ? "  ✓" : "")")
                        }
                    }
                }
                Section("Arrow") {
                    Picker("Arrow style", selection: $model.style.arrowStyle) {
                        ForEach(ArrowStyle.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Text") {
                    Picker("Text style", selection: $model.style.textStyle) {
                        ForEach(TextStyle.allCases) { Text($0.label).tag($0) }
                    }
                }
                Toggle("Shadow", isOn: $model.style.shadow)
            } label: {
                Image(systemName: "lineweight")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Line width, text size, arrow and text style, shadow")
        }
    }

    private func name(of color: RGBA) -> String {
        switch color {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .black: return "Black"
        case .white: return "White"
        default: return "Custom"
        }
    }

    private func swatch(_ color: RGBA) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
        return image
    }
}

/// Feeds NSColorPanel picks into the editor's style.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private weak var model: EditorModel?

    func open(model: EditorModel) {
        self.model = model
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.color = model.style.color.nsColor
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        model?.style.color = RGBA(panel.color)
    }
}

private struct BackgroundPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        let bg = model.document.background
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Background", isOn: Binding(get: { bg.enabled }, set: { v in model.setBackground { $0.enabled = v } }))
                .toggleStyle(.switch)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(BackgroundSettings.presets.enumerated()), id: \.offset) { index, preset in
                    Button {
                        model.setBackground { $0.preset = index; $0.enabled = true }
                    } label: {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(LinearGradient(colors: preset.1.map { Color(nsColor: $0.nsColor) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 40, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(bg.enabled && bg.preset == index ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help(preset.0)
                }
            }
            slider("Padding", value: bg.padding, range: 8...160) { v in model.setBackground { $0.padding = v } }
            slider("Corners", value: bg.cornerRadius, range: 0...40) { v in model.setBackground { $0.cornerRadius = v } }
            Toggle("Shadow", isOn: Binding(get: { bg.shadow }, set: { v in model.setBackground { $0.shadow = v } }))
            Picker("Aspect ratio", selection: Binding(get: { bg.aspect }, set: { v in model.setBackground { $0.aspect = v } })) {
                ForEach(BackgroundAspect.allCases) { Text($0.label).tag($0) }
            }
        }
        .padding(16)
        .frame(width: 240)
    }

    private func slider(_ title: String, value: CGFloat, range: ClosedRange<CGFloat>, set: @escaping (CGFloat) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: { set($0.rounded()) }), in: range)
        }
    }
}

private struct EditorBottomBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Fit to Window") { model.zoom = nil; model.onZoomChange?() }
                ForEach([0.5, 1, 2] as [CGFloat], id: \.self) { z in
                    Button("\(Int(z * 100))%") { model.zoom = z; model.onZoomChange?() }
                }
            } label: {
                Text(model.zoom.map { "\(Int(($0 * 100).rounded()))%" } ?? "Fit")
                    .monospacedDigit()
            }
            .menuStyle(.button)
            .fixedSize()

            Spacer()
            if model.tool == .crop {
                Button("Cancel") { model.cancelCrop() }
                    .keyboardShortcut(.cancelAction)
                Button("Reset") { model.resetCrop() }
                Button("Apply Crop") { model.applyCrop() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else if let progress = model.uploadProgress {
                VStack(spacing: 3) {
                    Text(model.uploadLabel).font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: progress).frame(width: 200)
                }
            } else if let message = model.statusMessage {
                Text(message).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            } else {
                DragHandle(model: model)
                    .frame(width: 120, height: 30)
                    .help("Drag the edited image into any app")
            }
            Spacer()

            ShareSheetButton(model: model).frame(width: 34, height: 28).help("Share…")
            iconButton("doc.on.doc", help: "Copy (⌘C)") { model.copy() }
            shareButton(.private)
            shareButton(.public)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.bar)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 18) }
            .help(help)
    }

    /// Titled with the service it uploads to, since either button can use either service.
    private func shareButton(_ visibility: ShareVisibility) -> some View {
        let available = model.canShare(visibility)
        return Button { model.share(visibility) } label: {
            Label(model.shareService(visibility) ?? visibility.label, systemImage: "paperplane")
        }
        .disabled(!available || model.isUploading)
        .help(available ? model.shareHelp(visibility) : "Choose a \(visibility == .private ? "private" : "public") destination in Settings → Sharing")
    }
}

/// "Drag Me": drags a PNG of the edited result.
private struct DragHandle: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> DragHandleView { DragHandleView(model: model) }
    func updateNSView(_ view: DragHandleView, context: Context) {}
}

private final class DragHandleView: NSView, NSDraggingSource {
    let model: EditorModel
    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Brighter under the pointer, like the buttons beside it.
    private var hovered = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
        NSColor.labelColor.withAlphaComponent(hovered ? 0.16 : 0.09).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        let text = NSAttributedString(string: "≡  Drag Me  ≡", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url = model.exportDraft() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = model.renderedImage().map { NSImage(cgImage: $0, size: NSSize(width: 160, height: 160 * CGFloat($0.height) / CGFloat(max($0.width, 1)))) }
        item.setDraggingFrame(NSRect(origin: .zero, size: preview?.size ?? bounds.size), contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        hovered = false
        window?.invalidateCursorRects(for: self)
    }
}

/// The system share sheet (Messages, Mail, AirDrop…), anchored to its button.
private struct ShareSheetButton: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .push
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor final class Coordinator: NSObject {
        let model: EditorModel
        init(model: EditorModel) { self.model = model }
        @objc func share(_ sender: NSButton) {
            guard let url = model.exportDraft() else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
