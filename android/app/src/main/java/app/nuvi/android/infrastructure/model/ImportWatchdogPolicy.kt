package app.nuvi.android.infrastructure.model

object ImportWatchdogPolicy {
    const val PREFLIGHT_TIMEOUT_MS = 30L * 1_000L
    const val COPY_STALL_TIMEOUT_MS = 2L * 60L * 1_000L
    const val COPY_ABSOLUTE_TIMEOUT_MS = 20L * 60L * 1_000L
    const val MODEL_LOAD_ABSOLUTE_TIMEOUT_MS = 5L * 60L * 1_000L

    fun timeoutCode(journal: ImportJournal, nowMs: Long): String? {
        if (!journal.isActive) return null
        val stageElapsed = nowMs - journal.stageStartedAtMs
        return when (journal.stage) {
            ImportStage.PREFLIGHT -> if (stageElapsed >= PREFLIGHT_TIMEOUT_MS) "MODEL_PREFLIGHT_TIMEOUT" else null
            ImportStage.EXTRACTING, ImportStage.COPYING -> when {
                stageElapsed >= COPY_ABSOLUTE_TIMEOUT_MS -> "MODEL_COPY_TIMEOUT"
                nowMs - journal.updatedAtMs >= COPY_STALL_TIMEOUT_MS -> "MODEL_COPY_TIMEOUT"
                else -> null
            }
            // sherpa-onnx exposes no initialization progress callback. Process liveness is
            // tracked by the import-job lock; this policy enforces only the absolute bound.
            ImportStage.NATIVE_PROBE ->
                if (stageElapsed >= MODEL_LOAD_ABSOLUTE_TIMEOUT_MS) "MODEL_LOAD_TIMEOUT" else null
            else -> null
        }
    }
}
