package app.nuvi.android.infrastructure.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImportTerminationGateTest {
    @Test fun serviceCanTerminateOnlyItsCurrentlyOwnedCandidate() {
        assertTrue(ImportTerminationGate.shouldSelfTerminate(true, "current", "current"))
        assertFalse(ImportTerminationGate.shouldSelfTerminate(true, "new", "stale"))
        assertFalse(ImportTerminationGate.shouldSelfTerminate(false, null, "stale"))
    }
}
