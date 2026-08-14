import XCTest
@testable import Nuvi

final class TextInjectorTests: XCTestCase {
    func testUntrustedPreflightNeverSelectsClipboardFallback() {
        XCTAssertEqual(
            TextInjector.preflightPolicy(isAccessibilityTrusted: false),
            .directTypingWithoutClipboard
        )
        XCTAssertEqual(
            TextInjector.preflightPolicy(isAccessibilityTrusted: true),
            .classifyFocusedTarget
        )
    }

    func testUntrustedTypingAttemptNeverClaimsVerifiedInsertion() {
        for didPostEvent in [true, false] {
            switch TextInjector.untrustedAttemptResult(didPostEvent: didPostEvent) {
            case .manualFallback(let message):
                XCTAssertTrue(message.contains("nothing was copied"))
            case .inserted:
                XCTFail("Posting an unverified CGEvent must not claim insertion")
            case .clipboardOnly:
                XCTFail("Untrusted field safety must never select the clipboard")
            }
        }
    }

    func testSecureFieldWinsOverAIEditorAndBrowserRoutes() {
        XCTAssertEqual(
            TextInjector.route(
                frontmost: "com.openai.codex",
                focusedRole: "AXTextArea",
                focusedSubrole: "AXSecureTextField",
                isSecure: true
            ),
            .secureDirectTyping
        )
        XCTAssertTrue(TextInjector.isSecureTextField(focusedSubrole: nil, editableSubrole: "AXSecureTextField"))
    }

    func testAIEditorUsesVerifiedAXValueRoute() {
        XCTAssertEqual(
            TextInjector.route(
                frontmost: "com.anthropic.claudefordesktop",
                focusedRole: "AXTextArea",
                focusedSubrole: "AXTextInput",
                isSecure: false
            ),
            .aiEditorAXValue
        )
    }

    func testBrowserUsesClipboardRouteOnlyForNonSecureFields() {
        XCTAssertEqual(
            TextInjector.route(
                frontmost: "com.apple.Safari",
                focusedRole: "AXTextField",
                focusedSubrole: "AXSearchField",
                isSecure: false
            ),
            .webClipboardPaste
        )
    }

    func testGhostTextIsRemovedBeforeAppending() {
        let cleaned = TextInjector.editableValueRemovingGhostText(
            "Existing prompt\nType / for commands",
            ghostTexts: ["Type / for commands"]
        )
        XCTAssertEqual(cleaned, "Existing prompt")
    }

    func testSelectionReplacementClampsStaleRange() {
        let replacement = TextInjector.replacingSelection(
            in: "hello",
            range: CFRange(location: 99, length: 20),
            with: "!"
        )
        XCTAssertEqual(replacement.value, "hello!")
        XCTAssertEqual(replacement.caretLocation, 6)
    }
}
