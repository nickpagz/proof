import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, stored the way Carbon's hot key API wants them.
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, shiftKey, optionKey, controlKey).
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        // A global shortcut without ⌘, ⌥ or ⌃ would swallow ordinary typing. Function keys are the exception.
        let isFunctionKey = Shortcut.functionKeyCodes.contains(Int(event.keyCode))
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 || isFunctionKey else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Shortcut.keyName(Int(keyCode))
    }

    /// For NSMenuItem.keyEquivalent, so menus show the same shortcut.
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags)? {
        guard let character = Shortcut.characters[Int(keyCode)] else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return (character, flags)
    }

    private static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
    ]

    private static let characters: [Int: String] = {
        var map: [Int: String] = [
            kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
            kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
            kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
            kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
            kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
            kVK_ANSI_Z: "z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() {
            map[code] = String(UnicodeScalar(NSF1FunctionKey + index)!)
        }
        return map
    }()

    private static func keyName(_ code: Int) -> String {
        switch code {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            // Function key codes aren't contiguous, so look them up by position.
            let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            if let index = functionKeys.firstIndex(of: code) { return "F\(index + 1)" }
            return characters[code]?.uppercased() ?? "#\(code)"
        }
    }
}

/// Everything a global shortcut can trigger.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case allInOne, captureArea, capturePreviousArea, captureFullscreen, captureWindow, selfTimer
    case recordScreen, toggleDesktopIcons, restoreLastCapture

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allInOne: return "All-In-One"
        case .captureArea: return "Capture Area"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureWindow: return "Capture Window"
        case .selfTimer: return "Self-Timer"
        case .recordScreen: return "Record Screen"
        case .toggleDesktopIcons: return "Toggle Desktop Icons"
        case .restoreLastCapture: return "Restore Recently Closed"
        }
    }

    var symbolName: String {
        switch self {
        case .allInOne: return "square.dashed.inset.filled"
        case .captureArea: return "viewfinder"
        case .capturePreviousArea: return "arrow.counterclockwise"
        case .captureFullscreen: return "display"
        case .captureWindow: return "macwindow"
        case .selfTimer: return "timer"
        case .recordScreen: return "record.circle"
        case .toggleDesktopIcons: return "eye"
        case .restoreLastCapture: return "arrow.uturn.backward"
        }
    }

    /// The same keys CleanShot and macOS use, so muscle memory carries over. macOS's own
    /// screenshot shortcuts must be turned off for these to reach Proof.
    var defaultShortcut: Shortcut? {
        let cmdShift = UInt32(cmdKey | shiftKey)
        switch self {
        case .captureFullscreen: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: cmdShift)
        case .captureArea: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: cmdShift)
        case .allInOne: return Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: cmdShift)
        // Free on Macs without a Touch Bar; clear it in Settings → Shortcuts to use the menu only.
        case .recordScreen: return Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: cmdShift)
        default: return nil
        }
    }
}

/// Registers global shortcuts with Carbon's RegisterEventHotKey, which needs no Accessibility
/// permission. Registration fails when another app (or macOS) already owns the combination;
/// those actions are reported in `conflicts`.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var handler: ((HotKeyAction) -> Void)?
    private(set) var conflicts: Set<HotKeyAction> = []

    private var refs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: HotKeyAction] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x5052_4F46   // 'PROF'

    private init() {}

    func register(_ bindings: [HotKeyAction: Shortcut]) {
        installHandlerIfNeeded()
        unregisterAll()
        conflicts = []
        for (index, (action, shortcut)) in bindings.sorted(by: { $0.key.rawValue < $1.key.rawValue }).enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                             EventHotKeyID(signature: signature, id: id),
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actionsByID[id] = action
            } else {
                conflicts.insert(action)
                Log.note("hotkey \(shortcut.displayString) for \(action.rawValue) is taken (status \(status))")
            }
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actionsByID = [:]
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let center = HotKeyCenter.shared
            if hotKeyID.signature == center.signature, let action = center.actionsByID[hotKeyID.id] {
                DispatchQueue.main.async { center.handler?(action) }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
