package app.nuvi.android.infrastructure.asr

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class LocalAsrDiagnosticsTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun persistedEntryHasOnlySanitizedOperationalFields() {
        val diagnostics = LocalAsrDiagnostics(temporary.root)
        assertTrue(diagnostics.append(LocalAsrDiagnostics.Entry(
            requestId = "request/../../secret",
            stage = "complete",
            family = "PARAKEET",
            bundleVersion = "parakeet-123",
            pid = 42,
            causeClass = "java.lang.Illegal State",
            loadMillis = 120,
            decodeMillis = 30
        )))
        val raw = temporary.root.resolve("asr-diagnostics.v1").readText()
        assertTrue(raw.contains("request_.._.._secret"))
        assertFalse(raw.contains(" "))
        assertFalse(raw.contains("transcript"))
        assertFalse(raw.contains("audio"))
    }

    @Test fun writeFailureIsStrictlyBestEffort() {
        val blockedDirectory = temporary.newFile("not-a-directory")
        val diagnostics = LocalAsrDiagnostics(blockedDirectory)

        assertFalse(diagnostics.append(LocalAsrDiagnostics.Entry(
            requestId = "request",
            stage = "error",
            family = "PARAKEET",
            bundleVersion = "v1",
            pid = 42
        )))
    }
}
