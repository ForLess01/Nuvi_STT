package app.nuvi.android.infrastructure.asr

import java.util.concurrent.Executors

/** Schedules diagnostics only after protocol ownership is settled; failures never escape. */
class BestEffortAsrDiagnostics(
    private val append: (LocalAsrDiagnostics.Entry) -> Unit,
    private val schedule: ((() -> Unit) -> Unit) = { task -> executor.execute(task) }
) {
    fun afterProtocol(
        protocolAction: () -> Unit,
        entry: () -> LocalAsrDiagnostics.Entry
    ) {
        protocolAction()
        runCatching {
            schedule { runCatching { append(entry()) } }
        }
    }

    companion object {
        private val executor = Executors.newSingleThreadExecutor { task ->
            Thread(task, "nuvi-asr-diagnostics").apply { isDaemon = true }
        }
    }
}
