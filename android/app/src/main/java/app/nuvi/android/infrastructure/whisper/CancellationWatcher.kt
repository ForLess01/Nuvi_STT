package app.nuvi.android.infrastructure.whisper

import java.util.concurrent.atomic.AtomicBoolean

class CancellationWatcher(
    cancellation: AtomicBoolean,
    onCancel: () -> Unit,
    private val joinMillis: Long = 1_000L
) : AutoCloseable {
    private val worker = Thread {
        try {
            while (!cancellation.get() && !Thread.currentThread().isInterrupted) Thread.sleep(25)
            if (cancellation.get() && !Thread.currentThread().isInterrupted) onCancel()
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }.apply { name = "nuvi-whisper-cancel"; isDaemon = true; start() }

    override fun close() {
        worker.interrupt()
        var interrupted = false
        while (worker.isAlive) {
            try {
                worker.join(joinMillis)
            } catch (_: InterruptedException) {
                interrupted = true
            }
        }
        if (interrupted) Thread.currentThread().interrupt()
    }

    internal fun isAliveForTesting(): Boolean = worker.isAlive
}
