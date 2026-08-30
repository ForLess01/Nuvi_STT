import AppKit
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

    func testFailedClipboardPasteUsesManualFallbackForAIAndWebRoutes() {
        for targetName in ["editor", "web field"] {
            switch TextInjector.pasteAttemptResult(didPaste: false, targetName: targetName) {
            case .manualFallback(let reason):
                XCTAssertTrue(reason.contains("clipboard restored"))
                XCTAssertTrue(reason.contains("manual paste required"))
            case .inserted:
                XCTFail("A failed clipboard paste must not claim insertion")
            case .clipboardOnly:
                XCTFail("A failed clipboard paste must require manual fallback")
            }
        }

        if case .inserted = TextInjector.pasteAttemptResult(didPaste: true, targetName: "editor") {
            // A successful paste keeps the existing inserted result.
        } else {
            XCTFail("A successful clipboard paste should report insertion")
        }
    }

    func testFailedClipboardPasteRestoresTheOriginalContents() {
        let pasteboard = NSPasteboard(name: .init("NuviTests.TextInjector.\(UUID().uuidString)"))
        let original = "already copied"
        let dictated = "new transcription"

        for restoreClipboard in [true, false] {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString(original, forType: .string))

            let didPaste = TextInjector.pasteViaClipboard(
                dictated,
                restoreClipboard: restoreClipboard,
                pasteboard: pasteboard,
                sendPaste: { false }
            )

            XCTAssertFalse(didPaste)
            XCTAssertEqual(pasteboard.string(forType: .string), original)
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
    }

    func testAIEditorUsesVerifiedAXValueRoute() {
        XCTAssertEqual(
            TextInjector.route(
                frontmost: "com.anthropic.claudefordesktop",
                focusedRole: "AXTextArea",
                focusedSubrole: "AXTextInput",
                isSecure: false,
                hasFocusedElement: true,
                isInsideWebArea: false
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
                isSecure: false,
                hasFocusedElement: true,
                isInsideWebArea: false
            ),
            .webClipboardPaste
        )
    }

    func testSemanticPlaceholderIsRemovedOnlyWhenCharacterCountProvesNoCommittedText() {
        XCTAssertEqual(
            TextInjector.sanitizedEditableValue(
                "Do anything",
                semanticPlaceholder: "Do anything",
                committedCharacterCount: 0,
                descriptionGhostTexts: []
            ),
            ""
        )

        XCTAssertEqual(
            TextInjector.sanitizedEditableValue(
                "Do anything",
                semanticPlaceholder: "Do anything",
                committedCharacterCount: 11,
                descriptionGhostTexts: []
            ),
            "Do anything"
        )
    }

    func testAIEditorDefersToNativeInputWhenPromptMetadataMirrorsAXValue() {
        XCTAssertTrue(
            TextInjector.requiresNativeEditorInput(
                sanitizedValue: "Escribe cualquier cosa"
            )
        )
    }

    func testAIEditorDefersToNativeInputForAmbiguousTextAtZeroCaret() {
        XCTAssertTrue(
            TextInjector.requiresNativeEditorInput(
                sanitizedValue: "Dynamic suggestion"
            )
        )
    }

    func testAIEditorDefersCommittedTextSoTheAppPreservesItsOwnCaretSemantics() {
        XCTAssertTrue(
            TextInjector.requiresNativeEditorInput(
                sanitizedValue: "Existing committed text"
            )
        )
    }

    func testAIEditorNativeFallbackPreservesAmbiguousRealTextInsteadOfDeletingIt() {
        XCTAssertTrue(
            TextInjector.requiresNativeEditorInput(
                sanitizedValue: "Real text with caret at start"
            )
        )
    }

    func testAIEditorKeepsAXValuePathOnlyForAProvenEmptyEditor() {
        XCTAssertFalse(TextInjector.requiresNativeEditorInput(sanitizedValue: ""))
    }

    func testMultilineSemanticPlaceholderIsRemovedConservatively() {
        let placeholder = "Ask anything\nUse @ to add context"
        XCTAssertEqual(
            TextInjector.sanitizedEditableValue(
                placeholder,
                semanticPlaceholder: placeholder,
                committedCharacterCount: 0,
                descriptionGhostTexts: []
            ),
            ""
        )
    }

    func testDescriptionTextWithCommittedCharactersIsPreserved() {
        XCTAssertEqual(
            TextInjector.sanitizedEditableValue(
                "Existing prompt\nType / for commands",
                semanticPlaceholder: nil,
                committedCharacterCount: 15,
                descriptionGhostTexts: ["Type / for commands"]
            ),
            "Existing prompt\nType / for commands"
        )
        XCTAssertEqual(
            TextInjector.sanitizedEditableValue(
                "Ask for follow-up changes",
                semanticPlaceholder: nil,
                committedCharacterCount: 25,
                descriptionGhostTexts: ["Ask for follow-up changes"]
            ),
            "Ask for follow-up changes"
        )
    }

    func testAncestorWebAreaSelectsWebRouteWithoutBundleID() {
        XCTAssertTrue(TextInjector.containsWebArea(ancestorRoles: ["AXGroup", "AXWebArea", "AXWindow"]))
        XCTAssertEqual(
            TextInjector.route(
                frontmost: "com.example.embedded-browser",
                focusedRole: "AXTextArea",
                focusedSubrole: "AXTextInput",
                isSecure: false,
                hasFocusedElement: true,
                isInsideWebArea: true
            ),
            .webClipboardPaste
        )
    }

    func testUnknownFocusedTargetNeverSelectsClipboardRoute() {
        XCTAssertEqual(
            TextInjector.route(
                frontmost: "com.apple.Safari",
                focusedRole: "?",
                focusedSubrole: "?",
                isSecure: false,
                hasFocusedElement: false,
                isInsideWebArea: false
            ),
            .unknownFocusedTarget
        )
    }

    func testPresentButUnreadableFocusedElementNeverSelectsClipboardRoute() {
        XCTAssertEqual(
            TextInjector.route(
                frontmost: "com.apple.Safari",
                focusedRole: "?",
                focusedSubrole: "?",
                isSecure: false,
                hasFocusedElement: true,
                hasReadableAXMetadata: false,
                isInsideWebArea: false
            ),
            .unknownFocusedTarget
        )
    }

    func testAncestorZeroCharacterCountCannotAuthorizeRemovingTargetValue() {
        let target = TextInjector.EditorNodeMetadata(
            semanticPlaceholder: nil,
            committedCharacterCount: nil,
            description: nil
        )
        let ancestor = TextInjector.EditorNodeMetadata(
            semanticPlaceholder: "Do anything",
            committedCharacterCount: 0,
            description: "Type / for commands"
        )
        let metadata = TextInjector.resolveEditorTextMetadata(target: target, ancestors: [ancestor])

        XCTAssertNil(metadata.semanticPlaceholder)
        XCTAssertNil(metadata.committedCharacterCount)
        XCTAssertFalse(metadata.descriptionGhostTexts.contains("Type / for commands"))
        XCTAssertEqual(
            TextInjector.sanitizedEditableValue(
                "Do anything",
                semanticPlaceholder: metadata.semanticPlaceholder,
                committedCharacterCount: metadata.committedCharacterCount,
                descriptionGhostTexts: metadata.descriptionGhostTexts
            ),
            "Do anything"
        )
    }

    func testAXValuePrewriteTreatsAbsentAsEmptyButUnreadableAsUnsafe() {
        XCTAssertEqual(TextInjector.prewriteValue(from: .absent), .available(""))
        XCTAssertEqual(TextInjector.prewriteValue(from: .value("existing")), .available("existing"))
        XCTAssertEqual(TextInjector.prewriteValue(from: .unreadable), .unsafe)
    }

    func testProductionAXContinuationBlocksAllFallbackAfterAttemptedWrite() {
        for unavailableFallback in TextInjector.AXUnavailableFallback.allCases {
            XCTAssertEqual(
                TextInjector.continuation(
                    after: .attemptedUnverified,
                    whenUnavailable: unavailableFallback
                ),
                .manualFallback
            )
            XCTAssertEqual(
                TextInjector.continuation(
                    after: .unsafePrewrite,
                    whenUnavailable: unavailableFallback
                ),
                .manualFallback
            )
        }
    }

    func testProductionAXContinuationAllowsOnlyDesignedUnavailableFallback() {
        XCTAssertEqual(
            TextInjector.continuation(after: .unavailable, whenUnavailable: .clipboardPaste),
            .continueWith(.clipboardPaste)
        )
        XCTAssertEqual(
            TextInjector.continuation(after: .unavailable, whenUnavailable: .nextAXTarget),
            .continueWith(.nextAXTarget)
        )
        XCTAssertEqual(
            TextInjector.continuation(after: .unavailable, whenUnavailable: .directTyping),
            .continueWith(.directTyping)
        )
        XCTAssertEqual(
            TextInjector.continuation(after: .verified, whenUnavailable: .clipboardPaste),
            .inserted
        )
    }

    func testSuccessfulAXWriteRequiresSanitizedReadbackMatch() {
        XCTAssertEqual(
            TextInjector.writeOutcome(didAttempt: true, setSucceeded: true, readbackMatches: true),
            .verified
        )
        XCTAssertEqual(
            TextInjector.writeOutcome(didAttempt: true, setSucceeded: true, readbackMatches: false),
            .attemptedUnverified
        )
    }

    func testPositiveCharacterCountPreservesDescriptionTextDuringReadback() {
        let metadata = TextInjector.EditorTextMetadata(
            semanticPlaceholder: nil,
            committedCharacterCount: 5,
            descriptionGhostTexts: ["Type / for commands"]
        )
        XCTAssertFalse(
            TextInjector.readbackMatchesExpected(
                "hello\nType / for commands",
                expected: "hello",
                metadata: metadata
            )
        )
    }

    func testSameNodeDescriptionCanBeRemovedOnlyWhenCharacterCountProvesEmpty() {
        let target = TextInjector.EditorNodeMetadata(
            semanticPlaceholder: nil,
            committedCharacterCount: 0,
            description: "Escribe aquí tu consulta"
        )
        let metadata = TextInjector.resolveEditorTextMetadata(target: target, ancestors: [])

        XCTAssertTrue(metadata.descriptionGhostTexts.contains("Escribe aquí tu consulta"))
        XCTAssertEqual(
            TextInjector.sanitizedEditableValue(
                "  Escribe aquí tu consulta\n",
                semanticPlaceholder: metadata.semanticPlaceholder,
                committedCharacterCount: metadata.committedCharacterCount,
                descriptionGhostTexts: metadata.descriptionGhostTexts
            ),
            ""
        )
    }

    func testSameNodeDescriptionMismatchIsPreservedEvenWithZeroCommittedCharacters() {
        let metadata = TextInjector.resolveEditorTextMetadata(
            target: TextInjector.EditorNodeMetadata(
                semanticPlaceholder: nil,
                committedCharacterCount: 0,
                description: "質問を入力してください"
            ),
            ancestors: []
        )

        XCTAssertEqual(
            TextInjector.sanitizedEditableValue(
                "実際の内容",
                semanticPlaceholder: metadata.semanticPlaceholder,
                committedCharacterCount: metadata.committedCharacterCount,
                descriptionGhostTexts: metadata.descriptionGhostTexts
            ),
            "実際の内容"
        )
    }

    func testSameNodeDescriptionIsPreservedWhenCharacterCountIsUnknown() {
        let metadata = TextInjector.resolveEditorTextMetadata(
            target: TextInjector.EditorNodeMetadata(
                semanticPlaceholder: nil,
                committedCharacterCount: nil,
                description: "Escribe aquí tu consulta"
            ),
            ancestors: []
        )

        XCTAssertTrue(metadata.descriptionGhostTexts.isEmpty)
        XCTAssertEqual(
            TextInjector.sanitizedEditableValue(
                "Escribe aquí tu consulta",
                semanticPlaceholder: metadata.semanticPlaceholder,
                committedCharacterCount: metadata.committedCharacterCount,
                descriptionGhostTexts: metadata.descriptionGhostTexts
            ),
            "Escribe aquí tu consulta"
        )
    }

    func testPartialUnreadableSecurityMetadataFailsClosed() {
        let classification = TextInjector.classifyTargetSecurity(
            focusedRole: .value("AXTextField"),
            focusedSubrole: .unreadable,
            editableRole: nil,
            editableSubrole: nil
        )

        XCTAssertEqual(classification, .unknown)
        XCTAssertEqual(
            TextInjector.route(
                frontmost: "com.apple.Safari",
                focusedRole: "AXTextField",
                focusedSubrole: "?",
                isSecure: false,
                hasFocusedElement: true,
                hasReadableAXMetadata: classification != .unknown,
                isInsideWebArea: false
            ),
            .unknownFocusedTarget
        )
    }

    func testUnsupportedSubroleIsLegitimateAbsenceButSecureValueIsDetected() {
        XCTAssertEqual(
            TextInjector.classifyTargetSecurity(
                focusedRole: .value("AXTextField"),
                focusedSubrole: .absent,
                editableRole: nil,
                editableSubrole: nil
            ),
            .nonSecure
        )
        XCTAssertEqual(
            TextInjector.classifyTargetSecurity(
                focusedRole: .value("AXTextField"),
                focusedSubrole: .value("AXSecureTextField"),
                editableRole: nil,
                editableSubrole: nil
            ),
            .secure
        )
    }

    func testGhostTextWithoutProvenanceIsPreserved() {
        let cleaned = TextInjector.editableValueRemovingGhostText(
            "Existing prompt\nType / for commands",
            ghostTexts: ["Type / for commands"]
        )
        XCTAssertEqual(cleaned, "Existing prompt\nType / for commands")
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

    func testLiveRevisionTypesOnlyTheNewSuffix() {
        XCTAssertEqual(
            TextInjector.liveRevision(from: "Hello", to: "Hello world"),
            .init(backspaceCount: 0, suffix: " world")
        )
    }

    func testLiveRevisionReplacesAnUnstableSuffixByGraphemeCluster() {
        XCTAssertEqual(
            TextInjector.liveRevision(from: "I like café", to: "I like coffee"),
            .init(backspaceCount: 3, suffix: "offee")
        )
    }

    func testLiveCompletionNeverClaimsInsertionWithoutTargetReadback() {
        XCTAssertEqual(
            TextInjector.liveDeliveryConfirmation(
                updateSucceeded: true,
                readbackVerified: false
            ),
            .clipboardOnly
        )
        XCTAssertEqual(
            TextInjector.liveDeliveryConfirmation(
                updateSucceeded: false,
                readbackVerified: true
            ),
            .clipboardOnly
        )
        XCTAssertEqual(
            TextInjector.liveDeliveryConfirmation(
                updateSucceeded: true,
                readbackVerified: true
            ),
            .inserted
        )
    }
}
