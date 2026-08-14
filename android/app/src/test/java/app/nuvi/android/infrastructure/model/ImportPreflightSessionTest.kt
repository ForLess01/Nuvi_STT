package app.nuvi.android.infrastructure.model

import app.nuvi.android.domain.ModelFamily
import org.junit.Assert.assertEquals
import org.junit.Test

class ImportPreflightSessionTest {
    @Test fun providerInspectionTimeRemainsInsidePreflightDeadline() {
        val preflight = ImportPreflightSession.begin(
            provisionalFamily = ModelFamily.PARAKEET,
            nowMs = 1_000L,
            workerPid = 42,
            candidateId = "candidate"
        )
        val identified = ImportPreflightSession.identify(
            preflight,
            ModelStore.ImportSource(ModelFamily.WHISPER, "model.bin", "opaque", 10L),
            nowMs = 30_999L
        )

        assertEquals(1_000L, identified.stageStartedAtMs)
        assertEquals(ModelFamily.WHISPER, identified.family)
        assertEquals(
            "MODEL_PREFLIGHT_TIMEOUT",
            ImportWatchdogPolicy.timeoutCode(identified, 31_000L)
        )
    }
}
