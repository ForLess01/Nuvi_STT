package app.nuvi.android.application

import app.nuvi.android.infrastructure.model.ImportStage
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImportProgressThrottleTest {
    @Test fun duplicateAndHighFrequencyProgressIsBoundedButTerminalWins() {
        var now = 1_000L
        val throttle = ImportProgressThrottle({ now }, minimumIntervalMs = 200L)

        assertTrue(throttle.shouldEmit(ImportStage.EXTRACTING, 1))
        assertFalse(throttle.shouldEmit(ImportStage.EXTRACTING, 1))
        now += 30
        assertFalse(throttle.shouldEmit(ImportStage.EXTRACTING, 2))
        now += 170
        assertTrue(throttle.shouldEmit(ImportStage.EXTRACTING, 3))
        now += 1
        assertTrue(throttle.shouldEmit(ImportStage.NATIVE_PROBE, 92))
        assertTrue(throttle.shouldEmit(ImportStage.COMPLETE, 100))
    }
}
