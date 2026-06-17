import Foundation
import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon's RegisterEventHotKey.
///
/// Carbon triggers globally WITHOUT requiring Accessibility permission. We listen
/// to BOTH pressed and released so a hotkey can drive push-to-talk (hold to
/// record, release to stop). Multiple hotkeys share one installed handler,
/// dispatched by hotkey id + event kind.
public final class GlobalHotkey {
    private let id: UInt32
    private let onPress: () -> Void
    private let onRelease: (() -> Void)?
    private var ref: EventHotKeyRef?

    private static let signature: OSType = 0x4E555649 // 'NUVI'
    private static var handlers: [UInt32: GlobalHotkey] = [:]
    private static var installed = false

    public init(id: UInt32, onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) {
        self.id = id
        self.onPress = onPress
        self.onRelease = onRelease
    }

    @discardableResult
    public func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        GlobalHotkey.installHandlerIfNeeded()
        GlobalHotkey.handlers[id] = self
        let hotKeyID = EventHotKeyID(signature: GlobalHotkey.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            GlobalHotkey.handlers[id] = nil
            ref = nil
        }
        return status
    }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        GlobalHotkey.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            let kind = GetEventKind(event)
            guard let handler = GlobalHotkey.handlers[hotKeyID.id] else { return noErr }
            if kind == UInt32(kEventHotKeyPressed) {
                handler.onPress()
            } else if kind == UInt32(kEventHotKeyReleased) {
                handler.onRelease?()
            }
            return noErr
        }, 2, &types, nil, nil)
    }
}

/// Stable hotkey identifiers.
public enum HotkeyID {
    public static let toggleDictation: UInt32 = 1
    public static let cycleMode: UInt32 = 2
    public static let pushToTalk: UInt32 = 3
    public static let cancel: UInt32 = 4
}
