package app.nuvi.android.application

import app.nuvi.android.infrastructure.model.ImportStage

/** Limits disk writes/broadcasts while always publishing stage changes and terminal states. */
class ImportProgressThrottle(
    private val nowMs: () -> Long,
    private val minimumIntervalMs: Long = 200L
) {
    private var lastStage: ImportStage? = null
    private var lastPercent = -1
    private var lastEmissionMs = Long.MIN_VALUE

    @Synchronized fun shouldEmit(stage: ImportStage, percent: Int): Boolean {
        val normalized = percent.coerceIn(0, 100)
        if (stage == lastStage && normalized == lastPercent) return false
        val now = nowMs()
        val stageChanged = stage != lastStage
        val due = lastEmissionMs == Long.MIN_VALUE || now - lastEmissionMs >= minimumIntervalMs
        if (!stageChanged && !stage.terminal && !due) return false
        lastStage = stage
        lastPercent = normalized
        lastEmissionMs = now
        return true
    }
}
