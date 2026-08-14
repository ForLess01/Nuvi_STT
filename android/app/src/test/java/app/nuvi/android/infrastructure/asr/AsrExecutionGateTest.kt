package app.nuvi.android.infrastructure.asr

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AsrExecutionGateTest {
    @Test fun cancellationBeforeAcceptedAuthorizationPreventsNativeExecution() {
        val gate = AsrExecutionGate()

        assertTrue(gate.prepare("request-1"))
        assertTrue(gate.cancel("request-1"))

        assertFalse(gate.authorize("request-1"))
        assertFalse(gate.ownsActive("request-1"))
    }

    @Test fun acknowledgedRequestCanExecuteAndReleasesOwnership() {
        val gate = AsrExecutionGate()

        assertTrue(gate.prepare("request-1"))
        assertTrue(gate.authorize("request-1"))
        assertTrue(gate.ownsActive("request-1"))

        gate.finish("request-1")
        assertTrue(gate.prepare("request-2"))
    }
}
