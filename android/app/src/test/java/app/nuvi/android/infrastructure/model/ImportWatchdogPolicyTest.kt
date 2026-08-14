package app.nuvi.android.infrastructure.model

import app.nuvi.android.domain.ModelFamily
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ImportWatchdogPolicyTest {
    @Test fun fourMinuteProbeIsAllowedWithoutFakeHeartbeatProgress() {
        val journal = probe(stageStarted = 0L, legacyHeartbeat = 1_000L)
        assertNull(ImportWatchdogPolicy.timeoutCode(journal, 240_000L))
    }

    @Test fun fiveMinuteProbeHasDistinctModelLoadTimeout() {
        val journal = probe(stageStarted = 0L, legacyHeartbeat = 299_000L)
        assertEquals("MODEL_LOAD_TIMEOUT", ImportWatchdogPolicy.timeoutCode(journal, 300_000L))
    }

    @Test fun staleLegacyHeartbeatDoesNotPretendNativeProbeStalled() {
        val journal = probe(stageStarted = 0L, legacyHeartbeat = 1_000L)
        assertNull(ImportWatchdogPolicy.timeoutCode(journal, 299_999L))
    }

    @Test fun stalledArchiveUsesCopyTimeoutNotEngineTimeout() {
        val journal = probe(0L, 0L).copy(stage = ImportStage.EXTRACTING, updatedAtMs = 0L)
        assertEquals("MODEL_COPY_TIMEOUT", ImportWatchdogPolicy.timeoutCode(journal, 120_000L))
    }

    @Test fun stalledPreflightHasDistinctTimeoutCode() {
        val journal = probe(0L, 0L).copy(stage = ImportStage.PREFLIGHT, stageStartedAtMs = 0L)
        assertEquals("MODEL_PREFLIGHT_TIMEOUT", ImportWatchdogPolicy.timeoutCode(journal, 30_000L))
    }

    private fun probe(stageStarted: Long, legacyHeartbeat: Long) = ImportJournal(
        family = ModelFamily.PARAKEET,
        sourceLabel = "Parakeet",
        sourceId = "opaque",
        stage = ImportStage.NATIVE_PROBE,
        percent = 92,
        startedAtMs = 0L,
        updatedAtMs = legacyHeartbeat,
        candidateId = "candidate",
        stageStartedAtMs = stageStarted,
        heartbeatAtMs = legacyHeartbeat,
        workerPid = 123
    )
}
