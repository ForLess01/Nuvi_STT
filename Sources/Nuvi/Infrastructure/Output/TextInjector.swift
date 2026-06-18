import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Outcome of trying to place transcribed text.
public enum InjectionResult: Sendable {
    case inserted                // inserted into the focused text field/editor
    case clipboardOnly(String)   // left on the clipboard, with a reason
}

/// Places transcribed text into whatever app has focus.
///
/// Order of attempts:
///   1. Direct Accessibility insertion when the focused element supports it.
///   2. Direct Unicode typing into a focused editable element.
///   3. Clipboard fallback only when no editable target is available/trusted.
public enum TextInjector {
    @discardableResult
    public static func ensureAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    @MainActor
    public static func insert(_ text: String, restoreClipboard: Bool) -> InjectionResult {
        let trusted = AXIsProcessTrusted()
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        NSLog("Nuvi/inject: trusted=\(trusted), frontmost=\(frontmost), characters=\(text.count)")

        guard trusted else {
            writeClipboardOnly(text)
            NSLog("Nuvi/inject: Accessibility NOT trusted → clipboard")
            return .clipboardOnly("Copied to clipboard — Accessibility not granted")
        }

        let element = focusedElement()
        let role = element.flatMap { stringAttribute($0, kAXRoleAttribute as String) } ?? "?"
        let subrole = element.flatMap { stringAttribute($0, kAXSubroleAttribute as String) } ?? "?"
        let editable = element.flatMap(editableElement(startingAt:))
        NSLog("Nuvi/inject: focused role=\(role), subrole=\(subrole), editableTarget=\(editable != nil)")

        // Web content (browsers / AXWebArea) FIRST: AX text insertion frequently
        // reports success but silently does nothing in web inputs (e.g. the
        // YouTube search box). Trying it first would short-circuit and leave the
        // user with nothing — not even on the clipboard. So route web straight to
        // the reliable path: clipboard paste, or direct typing for secure fields.
        if isWebContext(frontmost: frontmost, focusedRole: role, focusedSubrole: subrole) {
            if subrole == "AXSecureTextField" {
                NSLog("Nuvi/inject: secure web field → direct typing")
                typeUnicode(text)
            } else {
                NSLog("Nuvi/inject: web target → clipboard paste")
                pasteViaClipboard(text, restoreClipboard: restoreClipboard)
            }
            return .inserted
        }

        // Native apps: direct Accessibility insertion where supported.
        if let element, axInsert(element, text) {
            NSLog("Nuvi/inject: direct AX insert")
            return .inserted
        }

        if let editable {
            if axInsert(editable, text) {
                NSLog("Nuvi/inject: direct AX insert via editable ancestor")
                return .inserted
            }
            NSLog("Nuvi/inject: direct Unicode typing")
            typeUnicode(text)
            return .inserted
        }

        writeClipboardOnly(text)
        NSLog("Nuvi/inject: no editable target → clipboard")
        return .clipboardOnly("Copied to clipboard — no text field focused")
    }

    // MARK: - Accessibility helpers

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func editableElement(startingAt element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0

        while let candidate = current, depth < 8 {
            if isEditable(candidate) { return candidate }
            current = parent(of: candidate)
            depth += 1
        }

        return nil
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &ref) == .success,
              let raw = ref,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    /// Insert text at the current selection/cursor. Returns true on success.
    private static func axInsert(_ element: AXUIElement, _ text: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Broad editable test, biased toward "yes" (the failure we care about is a
    /// real field not being pasted into).
    private static func isEditable(_ element: AXUIElement) -> Bool {
        var namesRef: CFArray?
        if AXUIElementCopyAttributeNames(element, &namesRef) == .success,
           let attrs = namesRef as? [String] {
            let textAttrs: Set<String> = [
                kAXSelectedTextRangeAttribute as String,
                kAXInsertionPointLineNumberAttribute as String,
                kAXSelectedTextAttribute as String,
                kAXNumberOfCharactersAttribute as String
            ]
            if !attrs.isEmpty, !textAttrs.isDisjoint(with: attrs) { return true }
        }

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }

        let role = stringAttribute(element, kAXRoleAttribute as String)
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)
        let roles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        let subroles: Set<String> = ["AXSecureTextField", "AXSearchField", "AXTextInput"]
        if let role, roles.contains(role) { return true }
        if let subrole, subroles.contains(subrole) { return true }
        return false
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// True when the focus is inside web content (a browser app or an AXWebArea),
    /// where AX text insertion is unreliable. `insert(_:)` decides the actual
    /// strategy: clipboard paste normally, or direct typing for secure fields so
    /// a password never transits the pasteboard.
    private static func isWebContext(frontmost: String, focusedRole: String, focusedSubrole: String) -> Bool {
        if focusedRole == "AXWebArea" || focusedSubrole == "AXWebArea" { return true }
        return browserBundleIdentifiers.contains(frontmost)
    }

    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.kagi.kagimacOS"
    ]

    private static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0

        let units = Array(text.utf16)
        let chunkSize = 32
        var offset = 0

        while offset < units.count {
            let end = min(offset + chunkSize, units.count)
            var chunk = Array(units[offset..<end])
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.post(tap: .cghidEventTap)
            }
            usleep(12_000)
            offset = end
        }
    }

    private static func pasteViaClipboard(_ text: String, restoreClipboard: Bool) {
        let pasteboard = NSPasteboard.general
        let snapshot = restoreClipboard ? PasteboardSnapshot.capture(from: pasteboard) : nil
        writeClipboardOnly(text)
        sendPasteShortcut()

        guard restoreClipboard, let snapshot else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            snapshot.restore(to: pasteboard, ifCurrentStringIs: text)
        }
    }

    private static func sendPasteShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    private static func writeClipboardOnly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct PasteboardSnapshot {
    private let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(types: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard, ifCurrentStringIs expected: String) {
        guard pasteboard.string(forType: .string) == expected else { return }
        pasteboard.clearContents()
        let restoredItems = items.map { item in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.types {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }

    private struct Item {
        let types: [(NSPasteboard.PasteboardType, Data)]
    }
}
