import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Outcome of trying to place transcribed text.
public enum InjectionResult: Sendable {
    case inserted                // inserted into the focused text field/editor
    case clipboardOnly(String)   // left on the clipboard, with a reason
    case manualFallback(String)  // nothing copied; user action is required
}

/// Places transcribed text into whatever app has focus.
///
/// Order of attempts:
///   1. Direct Accessibility insertion when the focused element supports it.
///   2. Direct Unicode typing into a focused editable element.
///   3. Clipboard fallback only after a trusted AX inspection establishes that
///      the target is not a secure field.
public enum TextInjector {
    struct LiveRevision: Equatable {
        let backspaceCount: Int
        let suffix: String
    }

    enum LiveDeliveryConfirmation: Equatable {
        case inserted
        case clipboardOnly
    }

    @MainActor
    final class LiveSession {
        let processIdentifier: pid_t
        let editableElement: AXUIElement?
        var clipboardSnapshot: PasteboardSnapshot?
        let hooks: LiveHooks?
        var hasCapturedClipboard = false
        var lastClipboardChangeCount: Int?
        var text = ""
        var isValid = true
        var lastClipboardWrite: String?
        var lastUpdateWasVerified = false

        init(
            processIdentifier: pid_t,
            editableElement: AXUIElement,
            clipboardSnapshot: PasteboardSnapshot? = nil
        ) {
            hooks = nil
            self.processIdentifier = processIdentifier
            self.editableElement = editableElement
            self.clipboardSnapshot = clipboardSnapshot
        }
        init(hooks: LiveHooks) {
            self.hooks = hooks
            processIdentifier = 0
            editableElement = nil
            clipboardSnapshot = nil
        }

    }

    @MainActor
    struct LiveHooks {
        var validate: () -> Bool
        var backspace: () -> Bool
        var paste: (String) -> Bool
        var readback: (String) -> Bool
        var restore: () -> Void
        var sleep: (UInt64) async throws -> Void
        var capture: (() -> Void)? = nil
    }

    enum PreflightPolicy: Equatable {
        case classifyFocusedTarget
        case directTypingWithoutClipboard
    }

    enum InjectionRoute: Equatable {
        case unknownFocusedTarget
        case secureDirectTyping
        case aiEditorAXValue
        case webClipboardPaste
        case nativeAccessibility
    }

    enum AXWriteOutcome: Equatable {
        case unavailable
        case unsafePrewrite
        case verified
        case attemptedUnverified
    }

    enum AXPrewriteValue: Equatable {
        case available(String)
        case unsafe
    }

    enum AXUnavailableFallback: CaseIterable, Equatable {
        case clipboardPaste
        case nextAXTarget
        case directTyping
    }

    enum AXContinuation: Equatable {
        case inserted
        case manualFallback
        case continueWith(AXUnavailableFallback)
    }

    enum AXStringAttributeRead: Equatable {
        case value(String)
        case absent
        case unreadable

        var stringValue: String? {
            guard case .value(let value) = self else { return nil }
            return value
        }
    }

    enum TargetSecurityClassification: Equatable {
        case unknown
        case secure
        case nonSecure
    }

    struct EditorNodeMetadata: Equatable {
        var semanticPlaceholder: String?
        var committedCharacterCount: Int?
        var description: String?
    }

    struct EditorTextMetadata: Equatable {
        var semanticPlaceholder: String?
        var committedCharacterCount: Int?
        var descriptionGhostTexts: Set<String>
    }

    @discardableResult
    public static func ensureAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    @MainActor
    static func beginLiveSession() -> LiveSession? {
        guard AXIsProcessTrusted(),
              let element = focusedElement() else { return nil }

        guard let editable = editableElement(startingAt: element) else { return nil }
        var targetProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(editable, &targetProcessIdentifier) == .success,
              targetProcessIdentifier > 0 else { return nil }
        let focusedRole = stringAttributeRead(element, kAXRoleAttribute as String)
        let focusedSubrole = stringAttributeRead(element, kAXSubroleAttribute as String)
        let editableRole = stringAttributeRead(editable, kAXRoleAttribute as String)
        let editableSubrole = stringAttributeRead(editable, kAXSubroleAttribute as String)
        guard classifyTargetSecurity(
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole,
            editableRole: editableRole,
            editableSubrole: editableSubrole
        ) == .nonSecure else { return nil }

        return LiveSession(
            processIdentifier: targetProcessIdentifier,
            editableElement: editable
        )
    }

    @MainActor
    static func updateLiveSession(_ session: LiveSession, with text: String) async -> Bool {
        (try? await TextInsertionQueue.shared.run {
            await reviseLiveSession(session, with: text)
        }) ?? false
    }

    @MainActor
    fileprivate static func reviseLiveSession(_ session: LiveSession, with text: String,
                                          removingCancelledText: Bool = false) async -> Bool {
        func valid() -> Bool {
            !Task.isCancelled && (session.isValid || removingCancelledText) && liveTargetIsStillFocused(session)
        }
        guard valid() else { session.isValid = false; return false }
        // Capture only after acquiring the output queue: a previous session's
        // queued rollback may still own the temporary clipboard at begin().
        if !session.hasCapturedClipboard {
            if let hooks = session.hooks { hooks.capture?() }
            else { session.clipboardSnapshot = PasteboardSnapshot.capture(from: .general) }
            session.hasCapturedClipboard = true
        }
        let revision = liveRevision(from: session.text, to: text)
        for _ in 0..<revision.backspaceCount {
            guard valid(), session.hooks?.backspace() ?? postBackspaces(1) else { return false }
            // Record each posted mutation before suspending so cancellation can
            // remove only what this session actually sent.
            session.text.removeLast()
            guard await livePause(session, nanoseconds: 4_000_000, valid: valid) else { return false }
        }
        if revision.backspaceCount > 0, !revision.suffix.isEmpty {
            guard await livePause(session, nanoseconds: 20_000_000, valid: valid) else { return false }
        }
        if !revision.suffix.isEmpty {
            guard valid(), session.hooks?.paste(revision.suffix)
                ?? pasteViaClipboard(revision.suffix, restoreClipboard: false) else { return false }
            session.lastClipboardWrite = revision.suffix
            if session.hooks == nil { session.lastClipboardChangeCount = NSPasteboard.general.changeCount }
            session.text += revision.suffix
        }
        guard await livePause(session, nanoseconds: 100_000_000, valid: valid) else { return false }
        session.lastUpdateWasVerified = liveReadbackContains(session, text: text) == true
        return true
    }

    @MainActor
    private static func livePause(_ session: LiveSession, nanoseconds: UInt64,
                                  valid: () -> Bool) async -> Bool {
        await waitForTarget(nanoseconds: nanoseconds, valid: valid, sleep: session.hooks?.sleep ?? { nanos in
            try await Task.sleep(nanoseconds: nanos)
        })
    }

    @MainActor
    static func waitForTarget(nanoseconds: UInt64, valid: () -> Bool,
                              sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async -> Bool {
        do { try await sleep(nanoseconds) }
        catch { return false }
        return !Task.isCancelled && valid()
    }

    @MainActor
    static func cancelLiveSession(_ session: LiveSession) {
        session.isValid = false
        // Enqueue synchronously: a replacement session cannot overtake rollback.
        _ = TextInsertionQueue.shared.enqueue {
            _ = await reviseLiveSession(session, with: "", removingCancelledText: true)
            restoreLiveClipboard(session)
        }
    }

    static func liveRevision(from previous: String, to next: String) -> LiveRevision {
        let oldCharacters = Array(previous)
        let newCharacters = Array(next)
        var commonCount = 0
        while commonCount < oldCharacters.count,
              commonCount < newCharacters.count,
              oldCharacters[commonCount] == newCharacters[commonCount] {
            commonCount += 1
        }
        return LiveRevision(
            backspaceCount: oldCharacters.count - commonCount,
            suffix: String(newCharacters.dropFirst(commonCount))
        )
    }

    static func liveDeliveryConfirmation(
        updateSucceeded: Bool,
        readbackVerified: Bool
    ) -> LiveDeliveryConfirmation {
        updateSucceeded && readbackVerified ? .inserted : .clipboardOnly
    }

    @MainActor
    public static func insert(_ text: String, restoreClipboard: Bool) async -> InjectionResult {
        let process = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if !AXIsProcessTrusted() {
            let valid = { !Task.isCancelled && NSWorkspace.shared.frontmostApplication?.processIdentifier == process }
            return (try? await TextInsertionQueue.shared.run {
                untrustedAttemptResult(didPostEvent: await typeUnicode(text, valid: valid))
            }) ?? untrustedAttemptResult(didPostEvent: false)
        }
        guard let original = focusedElement() else {
            return .manualFallback("Focused target could not be classified — nothing was copied")
        }
        let initialSecurity = securityOfFocusedTarget(original)
        let valid = {
            !Task.isCancelled && NSWorkspace.shared.frontmostApplication?.processIdentifier == process
                && focusedElement().map { CFEqual($0, original) && securityOfFocusedTarget($0) == initialSecurity } == true
        }
        return (try? await TextInsertionQueue.shared.run {
            guard valid() else { return .manualFallback("Focused target changed — nothing was copied or typed") }
            return await insertUnserialized(text, restoreClipboard: restoreClipboard, valid: valid)
        }) ?? .manualFallback("Insertion cancelled — no further text was sent")
    }

    @MainActor
    private static func securityOfFocusedTarget(_ element: AXUIElement) -> TargetSecurityClassification {
        let editable = editableElement(startingAt: element)
        return classifyTargetSecurity(focusedRole: stringAttributeRead(element, kAXRoleAttribute as String),
            focusedSubrole: stringAttributeRead(element, kAXSubroleAttribute as String),
            editableRole: editable.map { stringAttributeRead($0, kAXRoleAttribute as String) },
            editableSubrole: editable.map { stringAttributeRead($0, kAXSubroleAttribute as String) })
    }

    @MainActor
    private static func insertUnserialized(_ text: String, restoreClipboard: Bool,
                                           valid: () -> Bool) async -> InjectionResult {
        let trusted = AXIsProcessTrusted()
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        NSLog("Nuvi/inject: trusted=\(trusted), frontmost=\(frontmost), characters=\(text.count)")

        switch preflightPolicy(isAccessibilityTrusted: trusted) {
        case .directTypingWithoutClipboard:
            // Without AX trust Nuvi cannot determine whether the focused field
            // is secure. Never put unknown text on NSPasteboard preemptively.
            NSLog("Nuvi/inject: Accessibility NOT trusted → direct typing without clipboard")
            return untrustedAttemptResult(didPostEvent: false)
        case .classifyFocusedTarget:
            break
        }

        let element = focusedElement()
        let focusedRoleRead = element.map {
            stringAttributeRead($0, kAXRoleAttribute as String)
        } ?? .unreadable
        let focusedSubroleRead = element.map {
            stringAttributeRead($0, kAXSubroleAttribute as String)
        } ?? .unreadable
        let role = focusedRoleRead.stringValue ?? "?"
        let subrole = focusedSubroleRead.stringValue ?? "?"
        let editable = element.flatMap(editableElement(startingAt:))
        let editableRoleRead = editable.map { stringAttributeRead($0, kAXRoleAttribute as String) }
        let editableSubroleRead = editable.map { stringAttributeRead($0, kAXSubroleAttribute as String) }
        let security = classifyTargetSecurity(
            focusedRole: focusedRoleRead,
            focusedSubrole: focusedSubroleRead,
            editableRole: editableRoleRead,
            editableSubrole: editableSubroleRead
        )
        let secure = security == .secure
        let isInsideWebArea = element.map { containsWebArea(ancestorRoles: ancestorRoles(startingAt: $0)) } ?? false
        let hasReadableAXMetadata = security != .unknown
        NSLog("Nuvi/inject: focused role=\(role), subrole=\(subrole), editableTarget=\(editable != nil)")

        switch route(
            frontmost: frontmost,
            focusedRole: role,
            focusedSubrole: subrole,
            isSecure: secure,
            hasFocusedElement: element != nil,
            hasReadableAXMetadata: hasReadableAXMetadata,
            isInsideWebArea: isInsideWebArea
        ) {
        case .unknownFocusedTarget:
            NSLog("Nuvi/inject: focused target unavailable → manual fallback")
            return .manualFallback("Focused target could not be classified — nothing was copied")

        case .secureDirectTyping:
            // This MUST precede every route that touches NSPasteboard. AI editors
            // and browsers can both expose secure descendants.
            NSLog("Nuvi/inject: secure field → direct typing")
            return await typeUnicode(text, valid: valid)
                ? .inserted
                : .manualFallback("Could not type into the secure field — nothing was copied")

        case .aiEditorAXValue:
            guard let element else {
                return .manualFallback("Focused target could not be classified — nothing was copied")
            }
            let target = editable ?? element
            let outcome = await axValueInsertVerified(target, text, insertion: .appendToEnd, valid: valid)
            switch continuation(after: outcome, whenUnavailable: .clipboardPaste) {
            case .inserted:
                return .inserted
            case .manualFallback:
                return .manualFallback(
                    manualFallbackReason(for: outcome, targetName: "editor")
                )
            case .continueWith(.clipboardPaste):
                return pasteAttemptResult(
                    didPaste: valid() && pasteViaClipboard(text, restoreClipboard: restoreClipboard),
                    targetName: "editor"
                )
            case .continueWith:
                return .manualFallback("Editor insertion stopped before an unsafe fallback — nothing was copied or typed")
            }

        case .webClipboardPaste:
            NSLog("Nuvi/inject: web target → clipboard paste")
            return pasteAttemptResult(
                didPaste: valid() && pasteViaClipboard(text, restoreClipboard: restoreClipboard),
                targetName: "web field"
            )

        case .nativeAccessibility:
            break
        }

        // Native apps: direct Accessibility insertion where supported.
        if let element {
            let outcome = await axSelectedTextInsertVerified(element, text, valid: valid)
            switch continuation(after: outcome, whenUnavailable: .nextAXTarget) {
            case .inserted:
                NSLog("Nuvi/inject: verified direct AX insert")
                return .inserted
            case .manualFallback:
                return .manualFallback(
                    manualFallbackReason(for: outcome, targetName: "focused field")
                )
            case .continueWith(.nextAXTarget):
                break
            case .continueWith:
                return .manualFallback("Focused-field insertion stopped before an unsafe fallback — nothing was copied or typed")
            }
        }

        if let editable {
            let outcome = await axSelectedTextInsertVerified(editable, text, valid: valid)
            switch continuation(after: outcome, whenUnavailable: .directTyping) {
            case .inserted:
                NSLog("Nuvi/inject: verified direct AX insert via editable ancestor")
                return .inserted
            case .manualFallback:
                return .manualFallback(
                    manualFallbackReason(for: outcome, targetName: "editable field")
                )
            case .continueWith(.directTyping):
                break
            case .continueWith:
                return .manualFallback("Editable-field insertion stopped before an unsafe fallback — nothing was copied or typed")
            }
            NSLog("Nuvi/inject: direct Unicode typing")
            return await typeUnicode(text, valid: valid)
                ? .inserted
                : .manualFallback("Could not type into the focused field — nothing was copied")
        }

        guard valid() else { return .manualFallback("Focused target changed — nothing was copied") }
        writeClipboardOnly(text)
        NSLog("Nuvi/inject: no editable target → clipboard")
        return .clipboardOnly("Copied to clipboard — no text field focused")
    }

    // MARK: - Accessibility helpers

    static func preflightPolicy(isAccessibilityTrusted: Bool) -> PreflightPolicy {
        isAccessibilityTrusted ? .classifyFocusedTarget : .directTypingWithoutClipboard
    }

    static func untrustedAttemptResult(didPostEvent: Bool) -> InjectionResult {
        if didPostEvent {
            return .manualFallback(
                "Direct typing was attempted, but Accessibility is required to verify insertion — nothing was copied"
            )
        }
        return .manualFallback(
            "Could not attempt direct typing; grant Accessibility and try again — nothing was copied"
        )
    }

    static func pasteAttemptResult(didPaste: Bool, targetName: String) -> InjectionResult {
        guard didPaste else {
            return .manualFallback(
                "Could not paste into the \(targetName) — nothing was copied; clipboard restored; manual paste required"
            )
        }
        return .inserted
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    @MainActor
    fileprivate static func liveTargetIsStillFocused(_ session: LiveSession) -> Bool {
        if let hooks = session.hooks { return hooks.validate() }
        guard let original = session.editableElement,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == session.processIdentifier,
              let current = focusedElement(),
              let currentEditable = editableElement(startingAt: current) else { return false }
        return CFEqual(currentEditable, original) && classifyTargetSecurity(
            focusedRole: stringAttributeRead(current, kAXRoleAttribute as String),
            focusedSubrole: stringAttributeRead(current, kAXSubroleAttribute as String),
            editableRole: stringAttributeRead(currentEditable, kAXRoleAttribute as String),
            editableSubrole: stringAttributeRead(currentEditable, kAXSubroleAttribute as String)
        ) == .nonSecure
    }

    @MainActor
    private static func liveReadbackContains(_ session: LiveSession, text: String) -> Bool? {
        if let hooks = session.hooks { return hooks.readback(text) }
        guard !text.isEmpty else { return true }
        guard let element = session.editableElement else { return nil }
        guard case .value(let rawValue) = stringAttributeRead(
            element,
            kAXValueAttribute as String
        ) else { return nil }
        let metadata = editorTextMetadata(startingAt: element)
        let value = sanitizedEditableValue(
            rawValue,
            semanticPlaceholder: metadata.semanticPlaceholder,
            committedCharacterCount: metadata.committedCharacterCount,
            descriptionGhostTexts: metadata.descriptionGhostTexts
        )
        return value.contains(text)
    }

    @MainActor
    static func restoreLiveClipboard(_ session: LiveSession) {
        if let hooks = session.hooks { hooks.restore(); return }
        guard let expected = session.lastClipboardWrite,
              NSPasteboard.general.changeCount == session.lastClipboardChangeCount else { return }
        session.clipboardSnapshot?.restore(to: .general, ifCurrentStringIs: expected)
        session.lastClipboardWrite = nil
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

    /// Inserts through AX only when the resulting value can be calculated and
    /// read back. Once a write was attempted, callers must not retry via another
    /// route because that could duplicate text that the target accepted slowly.
    @MainActor
    private static func axSelectedTextInsertVerified(_ element: AXUIElement, _ text: String, valid: () -> Bool) async -> AXWriteOutcome {
        guard valid() else { return .unsafePrewrite }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return .unavailable
        }

        let rawBefore: String
        switch prewriteValue(from: stringAttributeRead(element, kAXValueAttribute as String)) {
        case .available(let value):
            rawBefore = value
        case .unsafe:
            return .unsafePrewrite
        }
        let beforeMetadata = editorTextMetadata(startingAt: element)
        let before = sanitizedEditableValue(
            rawBefore,
            semanticPlaceholder: beforeMetadata.semanticPlaceholder,
            committedCharacterCount: beforeMetadata.committedCharacterCount,
            descriptionGhostTexts: beforeMetadata.descriptionGhostTexts
        )
        let range = selectedTextRange(of: element)
        guard range != nil || before.isEmpty else { return .unavailable }
        let expected = replacingSelection(in: before, range: range, with: text).value

        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard status == .success else {
            return writeOutcome(didAttempt: true, setSucceeded: false, readbackMatches: nil)
        }

        guard await waitForTarget(nanoseconds: 80_000_000, valid: valid) else { return .attemptedUnverified }
        guard let rawAfter = stringAttribute(element, kAXValueAttribute as String) else {
            return writeOutcome(didAttempt: true, setSucceeded: true, readbackMatches: nil)
        }
        let afterMetadata = editorTextMetadata(startingAt: element)
        let matches = readbackMatchesExpected(rawAfter, expected: expected, metadata: afterMetadata)
        return writeOutcome(didAttempt: true, setSucceeded: true, readbackMatches: matches)
    }

    private enum AXValueInsertion {
        case selectedRange
        case appendToEnd
    }

    @MainActor
    private static func axValueInsertVerified(
        _ element: AXUIElement,
        _ text: String,
        insertion: AXValueInsertion = .selectedRange,
        valid: () -> Bool
    ) async -> AXWriteOutcome {
        guard valid() else { return .unsafePrewrite }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return .unavailable
        }

        let rawBefore: String
        switch prewriteValue(from: stringAttributeRead(element, kAXValueAttribute as String)) {
        case .available(let value):
            rawBefore = value
        case .unsafe:
            return .unsafePrewrite
        }
        let metadata = editorTextMetadata(startingAt: element)
        let before = sanitizedEditableValue(
            rawBefore,
            semanticPlaceholder: metadata.semanticPlaceholder,
            committedCharacterCount: metadata.committedCharacterCount,
            descriptionGhostTexts: metadata.descriptionGhostTexts
        )
        // A non-empty AXValue in an AI editor is not trustworthy enough to
        // synthesize a replacement: Electron/web editors may expose visual
        // prompts as AXValue (sometimes even counting their characters). Let
        // the editor's native paste path decide what is committed instead. It
        // naturally dismisses placeholders while preserving real text and the
        // current caret/selection. Direct AXValue writes remain available for
        // editors that are provably empty.
        if requiresNativeEditorInput(sanitizedValue: before) {
            return .unavailable
        }
        let range = insertion == .appendToEnd || before.isEmpty ? nil : selectedTextRange(of: element)
        let replacement = replacingSelection(in: before, range: range, with: text)
        let next = replacement.value

        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, next as CFString)
        guard status == .success else {
            return writeOutcome(didAttempt: true, setSucceeded: false, readbackMatches: nil)
        }

        guard await waitForTarget(nanoseconds: 80_000_000, valid: valid) else { return .attemptedUnverified }
        guard let rawAfter = stringAttribute(element, kAXValueAttribute as String) else {
            return writeOutcome(didAttempt: true, setSucceeded: true, readbackMatches: nil)
        }
        let afterMetadata = editorTextMetadata(startingAt: element)
        let matches = readbackMatchesExpected(rawAfter, expected: next, metadata: afterMetadata)
        let outcome = writeOutcome(didAttempt: true, setSucceeded: true, readbackMatches: matches)
        if outcome == .verified {
            moveCaret(of: element, to: replacement.caretLocation, in: next)
        }
        return outcome
    }

    static func writeOutcome(
        didAttempt: Bool,
        setSucceeded: Bool,
        readbackMatches: Bool?
    ) -> AXWriteOutcome {
        guard didAttempt else { return .unavailable }
        guard setSucceeded, readbackMatches == true else { return .attemptedUnverified }
        return .verified
    }

    static func prewriteValue(from read: AXStringAttributeRead) -> AXPrewriteValue {
        switch read {
        case .value(let value):
            return .available(value)
        case .absent:
            return .available("")
        case .unreadable:
            return .unsafe
        }
    }

    static func requiresNativeEditorInput(sanitizedValue: String) -> Bool {
        !sanitizedValue.isEmpty
    }

    static func continuation(
        after outcome: AXWriteOutcome,
        whenUnavailable fallback: AXUnavailableFallback
    ) -> AXContinuation {
        switch outcome {
        case .verified:
            return .inserted
        case .unavailable:
            return .continueWith(fallback)
        case .unsafePrewrite, .attemptedUnverified:
            return .manualFallback
        }
    }

    private static func manualFallbackReason(
        for outcome: AXWriteOutcome,
        targetName: String
    ) -> String {
        switch outcome {
        case .unsafePrewrite:
            return "Could not safely read the \(targetName)'s existing text — nothing was copied or typed"
        case .attemptedUnverified:
            return "Text may have been inserted, but the \(targetName) did not confirm it — nothing else was copied or typed"
        case .unavailable, .verified:
            return "Insertion stopped before an unsafe fallback — nothing was copied or typed"
        }
    }

    static func readbackMatchesExpected(
        _ rawReadback: String,
        expected: String,
        metadata: EditorTextMetadata
    ) -> Bool {
        sanitizedEditableValue(
            rawReadback,
            semanticPlaceholder: metadata.semanticPlaceholder,
            committedCharacterCount: metadata.committedCharacterCount,
            descriptionGhostTexts: metadata.descriptionGhostTexts
        ) == expected
    }

    static func editableValueRemovingGhostText(_ value: String, ghostTexts: Set<String>) -> String {
        sanitizedEditableValue(
            value,
            semanticPlaceholder: nil,
            committedCharacterCount: nil,
            descriptionGhostTexts: ghostTexts
        )
    }

    static func sanitizedEditableValue(
        _ value: String,
        semanticPlaceholder: String?,
        committedCharacterCount: Int?,
        descriptionGhostTexts: Set<String>
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        // AXPlaceholderValue is semantic metadata, not committed content. Some
        // web editors mirror it into AXValue, but we remove it only when AX also
        // proves there are zero actual characters. Identical real user text is
        // therefore preserved.
        if committedCharacterCount == 0,
           let semanticPlaceholder,
           trimmed == semanticPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines) {
            return ""
        }

        if committedCharacterCount == 0, descriptionGhostTexts.contains(trimmed) { return "" }
        return value
    }

    private static func editorTextMetadata(startingAt element: AXUIElement) -> EditorTextMetadata {
        var nodes: [EditorNodeMetadata] = []
        var current: AXUIElement? = element
        var depth = 0

        while let candidate = current, depth < 4 {
            nodes.append(
                EditorNodeMetadata(
                    semanticPlaceholder: stringAttribute(candidate, "AXPlaceholderValue"),
                    committedCharacterCount: integerAttribute(
                        candidate,
                        kAXNumberOfCharactersAttribute as String
                    ),
                    description: stringAttribute(candidate, kAXDescriptionAttribute as String)
                )
            )
            current = parent(of: candidate)
            depth += 1
        }

        guard let target = nodes.first else {
            return EditorTextMetadata(
                semanticPlaceholder: nil,
                committedCharacterCount: nil,
                descriptionGhostTexts: []
            )
        }
        return resolveEditorTextMetadata(target: target, ancestors: Array(nodes.dropFirst()))
    }

    static func resolveEditorTextMetadata(
        target: EditorNodeMetadata,
        ancestors: [EditorNodeMetadata]
    ) -> EditorTextMetadata {
        // Text, placeholder, description, and character-count provenance must
        // stay on the same editable node. Ancestor metadata is intentionally
        // ignored because it cannot prove that the target has no committed text.
        _ = ancestors
        var descriptionGhostTexts = Set<String>()
        if target.committedCharacterCount == 0,
           let description = target.description {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { descriptionGhostTexts.insert(trimmed) }
        }

        let placeholder = target.semanticPlaceholder.flatMap { value -> String? in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        return EditorTextMetadata(
            semanticPlaceholder: placeholder,
            committedCharacterCount: target.committedCharacterCount,
            descriptionGhostTexts: descriptionGhostTexts
        )
    }

    private static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let value = ref as! AXValue
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    static func replacingSelection(in value: String, range: CFRange?, with text: String) -> (value: String, caretLocation: Int) {
        let insertedLength = (text as NSString).length
        guard let range, range.location >= 0, range.length >= 0 else {
            let nsLength = (value as NSString).length
            return (value + text, nsLength + insertedLength)
        }
        let nsValue = value as NSString
        let maxLocation = min(range.location, nsValue.length)
        let maxLength = min(range.length, nsValue.length - maxLocation)
        let next = nsValue.replacingCharacters(in: NSRange(location: maxLocation, length: maxLength), with: text)
        return (next, maxLocation + insertedLength)
    }

    private static func moveCaret(of element: AXUIElement, to desiredLocation: Int, in text: String) {
        let nsLength = (text as NSString).length
        var range = CFRange(location: min(max(desiredLocation, 0), nsLength), length: 0)
        guard let value = AXValueCreate(.cfRange, &range) else { return }
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
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

    private static func stringAttributeRead(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AXStringAttributeRead {
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        switch status {
        case .success:
            guard let value = ref as? String else { return .unreadable }
            return .value(value)
        case .attributeUnsupported, .noValue:
            return .absent
        default:
            return .unreadable
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        stringAttributeRead(element, attribute).stringValue
    }

    private static func integerAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let number = ref as? NSNumber else { return nil }
        return number.intValue
    }

    private static func ancestorRoles(startingAt element: AXUIElement) -> [String] {
        var roles: [String] = []
        var current: AXUIElement? = element
        var depth = 0
        while let candidate = current, depth < 12 {
            if let role = stringAttribute(candidate, kAXRoleAttribute as String) {
                roles.append(role)
            }
            current = parent(of: candidate)
            depth += 1
        }
        return roles
    }

    static func containsWebArea(ancestorRoles: [String]) -> Bool {
        ancestorRoles.contains("AXWebArea")
    }

    /// True when the focus is inside web content (a browser app or an AXWebArea),
    /// where AX text insertion is unreliable. `insert(_:)` decides the actual
    /// strategy: clipboard paste normally, or direct typing for secure fields so
    /// a password never transits the pasteboard.
    private static func isWebContext(
        frontmost: String,
        focusedRole: String,
        focusedSubrole: String,
        isInsideWebArea: Bool
    ) -> Bool {
        if isInsideWebArea || focusedRole == "AXWebArea" || focusedSubrole == "AXWebArea" { return true }
        return browserBundleIdentifiers.contains(frontmost)
    }

    static func route(
        frontmost: String,
        focusedRole: String,
        focusedSubrole: String,
        isSecure: Bool,
        hasFocusedElement: Bool = true,
        hasReadableAXMetadata: Bool = true,
        isInsideWebArea: Bool = false
    ) -> InjectionRoute {
        if !hasFocusedElement || !hasReadableAXMetadata { return .unknownFocusedTarget }
        if isSecure { return .secureDirectTyping }
        if isAIEditorTarget(frontmost) { return .aiEditorAXValue }
        if isWebContext(
            frontmost: frontmost,
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole,
            isInsideWebArea: isInsideWebArea
        ) {
            return .webClipboardPaste
        }
        return .nativeAccessibility
    }

    static func classifyTargetSecurity(
        focusedRole: AXStringAttributeRead,
        focusedSubrole: AXStringAttributeRead,
        editableRole: AXStringAttributeRead?,
        editableSubrole: AXStringAttributeRead?
    ) -> TargetSecurityClassification {
        let roleReads = [focusedRole] + [editableRole].compactMap { $0 }
        guard roleReads.allSatisfy({ read in
            if case .value = read { return true }
            return false
        }) else {
            return .unknown
        }

        let subroleReads = [focusedSubrole] + [editableSubrole].compactMap { $0 }
        if subroleReads.contains(.unreadable) { return .unknown }
        if subroleReads.contains(.value("AXSecureTextField")) { return .secure }
        return .nonSecure
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

    private static func isAIEditorTarget(_ bundleIdentifier: String) -> Bool {
        aiEditorBundleIdentifiers.contains(bundleIdentifier)
    }

    private static let aiEditorBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.anthropic.claudefordesktop",
        "com.google.antigravity",
        "com.google.antigravity-ide"
    ]

    @discardableResult
    @MainActor
    static func typeUnicode(_ text: String, valid: () -> Bool,
                            post: (([UniChar]) -> Bool)? = nil,
                            sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async -> Bool {
        if text.isEmpty { return true }
        let source = post == nil ? CGEventSource(stateID: .hidSystemState) : nil
        source?.localEventsSuppressionInterval = 0

        let units = Array(text.utf16)
        let chunkSize = 32
        var offset = 0
        var postedEvent = false

        while offset < units.count {
            guard valid() else { return false }
            let end = min(offset + chunkSize, units.count)
            var chunk = Array(units[offset..<end])
            if let post {
                guard post(chunk) else { return false }
                postedEvent = true
            } else if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.post(tap: .cghidEventTap)
                postedEvent = true
            }
            guard await waitForTarget(nanoseconds: 12_000_000, valid: valid, sleep: sleep) else { return false }
            offset = end
        }
        return postedEvent
    }

    @discardableResult
    private static func postBackspaces(_ count: Int) -> Bool {
        guard count > 0 else { return true }
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        for _ in 0..<count {
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_Delete),
                keyDown: true
            ), let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_Delete),
                keyDown: false
            ) else { return false }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        return true
    }

    @discardableResult
    static func pasteViaClipboard(
        _ text: String,
        restoreClipboard: Bool,
        pasteboard: NSPasteboard = .general,
        sendPaste: () -> Bool = sendPasteShortcut
    ) -> Bool {
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        guard writeClipboardOnly(text, to: pasteboard) else {
            snapshot.restore(to: pasteboard, ifCurrentStringIs: text)
            return false
        }
        let writeCount = pasteboard.changeCount
        guard sendPaste() else {
            snapshot.restore(to: pasteboard, ifCurrentStringIs: text, changeCount: writeCount)
            return false
        }

        guard restoreClipboard else { return true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard pasteboard.changeCount == writeCount else { return }
            snapshot.restore(to: pasteboard, ifCurrentStringIs: text)
        }
        return true
    }

    @discardableResult
    private static func sendPasteShortcut() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        guard let keyDown, let keyUp else { return false }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    private static func writeClipboardOnly(
        _ text: String,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

@MainActor
final class SystemLiveTextInjector: LiveTextInserting {
    private var session: TextInjector.LiveSession?

    func begin() -> Bool {
        session = TextInjector.beginLiveSession()
        return session != nil
    }

    func update(_ text: String) async -> Bool {
        guard let session else { return false }
        return await TextInjector.updateLiveSession(session, with: text)
    }

    func finish(_ text: String, restoreClipboard: Bool) async -> InjectionResult {
        guard let active = session else {
            return await TextInjector.insert(text, restoreClipboard: restoreClipboard)
        }
        defer { if session === active { session = nil } }
        return (try? await TextInsertionQueue.shared.run { [self] in
            let updateSucceeded = await TextInjector.reviseLiveSession(active, with: text)
            guard session === active, !Task.isCancelled,
                  active.isValid, TextInjector.liveTargetIsStillFocused(active) else {
                TextInjector.restoreLiveClipboard(active)
                return .manualFallback("Live insertion stopped because its target changed")
            }
            guard TextInjector.liveDeliveryConfirmation(
                updateSucceeded: updateSucceeded,
                readbackVerified: active.lastUpdateWasVerified
            ) == .inserted else {
                let pasteboard = NSPasteboard.general
                if let expected = active.lastClipboardChangeCount, pasteboard.changeCount != expected {
                    return .manualFallback("Clipboard changed while confirming live insertion")
                }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                return .clipboardOnly("Live text was sent, but the target did not confirm insertion")
            }
            if restoreClipboard {
                TextInjector.restoreLiveClipboard(active)
            } else {
                let pasteboard = NSPasteboard.general
                if active.lastClipboardChangeCount == nil || pasteboard.changeCount == active.lastClipboardChangeCount {
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }
            }
            return .inserted
        }) ?? .manualFallback("Live insertion cancelled — no further text was sent")
    }

    func cancel() {
        guard let active = session else { return }
        session = nil
        TextInjector.cancelLiveSession(active)
    }
}

struct PasteboardSnapshot {
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

    func restore(to pasteboard: NSPasteboard, ifCurrentStringIs expected: String, changeCount: Int? = nil) {
        if let changeCount, pasteboard.changeCount != changeCount { return }
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

/// Serializes native output across suspension points and session replacements.
@MainActor
final class TextInsertionQueue {
    static let shared = TextInsertionQueue()
    private var tail: Task<Void, Never>?

    func enqueue<Value>(_ operation: @escaping @MainActor () async throws -> Value) -> Task<Value, Error> {
        let predecessor = tail
        let work = Task { @MainActor in
            await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = await work.result }
        return work
    }

    func run<Value>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let work = enqueue(operation)
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
