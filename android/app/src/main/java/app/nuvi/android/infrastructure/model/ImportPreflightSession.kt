package app.nuvi.android.infrastructure.model

import app.nuvi.android.domain.ModelFamily
import java.util.UUID

/** Starts the preflight clock before any ContentProvider query or stream open can block. */
object ImportPreflightSession {
    fun begin(
        provisionalFamily: ModelFamily,
        nowMs: Long,
        workerPid: Int,
        candidateId: String = UUID.randomUUID().toString()
    ): ImportJournal = ImportJournal(
        family = provisionalFamily,
        sourceLabel = "Pending model",
        sourceId = "pending",
        stage = ImportStage.PREFLIGHT,
        percent = 0,
        startedAtMs = nowMs,
        updatedAtMs = nowMs,
        candidateId = candidateId,
        stageStartedAtMs = nowMs,
        heartbeatAtMs = nowMs,
        workerPid = workerPid
    )

    fun identify(
        preflight: ImportJournal,
        source: ModelStore.ImportSource,
        nowMs: Long
    ): ImportJournal {
        require(preflight.stage == ImportStage.PREFLIGHT)
        return preflight.copy(
            family = source.family,
            sourceLabel = source.displayName,
            sourceId = source.opaqueId,
            updatedAtMs = nowMs
        )
    }
}
