import AppKit
import Carbon.HIToolbox

/// A recorded keyboard shortcut. Source of truth for modifiers is the Cocoa
/// modifier flags (so we can represent fn and modifier-only combos); Carbon
/// flags are derived on demand for RegisterEventHotKey.
public struct KeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var cocoaModifierRaw: UInt
    public var keyLabel: String

    /// Sentinel key code meaning "modifiers only" (e.g. hold ⌘). These can't be
    /// registered via Carbon and run through a flagsChanged monitor instead.
    public static let modifierOnly: UInt32 = 0xFFFF

    /// Modifier flags we care about (excludes capsLock).
    public static let relevantMask: NSEvent.ModifierFlags =
        [.command, .control, .option, .shift, .function]

    public init(keyCode: UInt32, cocoaModifiers: NSEvent.ModifierFlags, keyLabel: String) {
        self.keyCode = keyCode
        self.cocoaModifierRaw = cocoaModifiers.intersection(KeyCombo.relevantMask).rawValue
        self.keyLabel = keyLabel
    }

    /// From a recorded key-down event (a normal key, optionally with modifiers).
    ///
    /// `extraModifiers` are merged in: the recorder tracks held modifiers via
    /// `flagsChanged`, and some key-down events don't carry every held modifier
    /// in `modifierFlags`. Merging guarantees combos like ⌘⇧K are captured whole
    /// instead of collapsing to a single key.
    public init(event: NSEvent, extraModifiers: NSEvent.ModifierFlags = []) {
        keyCode = UInt32(event.keyCode)
        let merged = event.modifierFlags
            .union(extraModifiers)
            .intersection(KeyCombo.relevantMask)
        cocoaModifierRaw = merged.rawValue
        keyLabel = KeyCombo.label(for: event)
    }

    /// A modifier-only combo (no regular key), e.g. hold ⌘ to talk.
    public init(modifierOnly flags: NSEvent.ModifierFlags) {
        keyCode = KeyCombo.modifierOnly
        cocoaModifierRaw = flags.intersection(KeyCombo.relevantMask).rawValue
        keyLabel = ""
    }

    public var isModifierOnly: Bool { keyCode == KeyCombo.modifierOnly }

    public var cocoaModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: cocoaModifierRaw).intersection(KeyCombo.relevantMask)
    }

    public var carbonModifiers: UInt32 {
        var c: UInt32 = 0
        let f = cocoaModifiers
        if f.contains(.command) { c |= UInt32(cmdKey) }
        if f.contains(.option)  { c |= UInt32(optionKey) }
        if f.contains(.control) { c |= UInt32(controlKey) }
        if f.contains(.shift)   { c |= UInt32(shiftKey) }
        return c
    }

    /// Individual keycaps for rendering, e.g. ["⌥", "⇧", "K"] or ["fn"].
    public var keyCaps: [String] {
        let f = cocoaModifiers
        var caps: [String] = []
        if f.contains(.function) { caps.append("fn") }
        if f.contains(.control)  { caps.append("⌃") }
        if f.contains(.option)   { caps.append("⌥") }
        if f.contains(.shift)    { caps.append("⇧") }
        if f.contains(.command)  { caps.append("⌘") }
        if !keyLabel.isEmpty { caps.append(keyLabel) }
        return caps.isEmpty ? ["—"] : caps
    }

    /// Human-readable, e.g. "⌥⇧K", "⌘Space", or "fn".
    public var displayString: String {
        let f = cocoaModifiers
        var s = ""
        if f.contains(.function) { s += "fn" }
        if f.contains(.control)  { s += "⌃" }
        if f.contains(.option)   { s += "⌥" }
        if f.contains(.shift)    { s += "⇧" }
        if f.contains(.command)  { s += "⌘" }
        s += keyLabel
        return s.isEmpty ? "—" : s
    }

    private static let specialKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6"
    ]

    private static func label(for event: NSEvent) -> String {
        if let name = specialKeys[event.keyCode] { return name }
        let chars = event.charactersIgnoringModifiers ?? ""
        return chars.isEmpty ? "Key\(event.keyCode)" : chars.uppercased()
    }

    // Sensible defaults.
    public static let toggleDefault = KeyCombo(keyCode: UInt32(kVK_Space),
                                               cocoaModifiers: .option, keyLabel: "Space")
    public static let cycleDefault  = KeyCombo(keyCode: UInt32(kVK_ANSI_K),
                                               cocoaModifiers: [.option, .shift], keyLabel: "K")
}
