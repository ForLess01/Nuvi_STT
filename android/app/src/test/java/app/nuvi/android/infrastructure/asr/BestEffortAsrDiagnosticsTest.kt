package app.nuvi.android.infrastructure.asr

import org.junit.Assert.assertTrue
import org.junit.Test

class BestEffortAsrDiagnosticsTest {
    @Test fun protocolCompletesBeforeFailingDiagnosticsAndFailureNeverEscapes() {
        var protocolComplete = false
        var diagnosticAttempted = false
        val reporter = BestEffortAsrDiagnostics(
            append = {
                diagnosticAttempted = true
                check(protocolComplete)
                error("disk unavailable")
            },
            schedule = { it() }
        )

        reporter.afterProtocol(
            protocolAction = { protocolComplete = true },
            entry = {
                check(protocolComplete)
                LocalAsrDiagnostics.Entry("request", "error", "PARAKEET", "v1", 42)
            }
        )

        assertTrue(protocolComplete)
        assertTrue(diagnosticAttempted)
    }
}
