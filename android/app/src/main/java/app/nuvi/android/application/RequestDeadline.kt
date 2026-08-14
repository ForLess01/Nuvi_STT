package app.nuvi.android.application

import app.nuvi.android.domain.TranscriptionErrorCode
import app.nuvi.android.domain.TranscriptionFailure
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

object RequestDeadline {
    fun <T> arm(
        future: CompletableFuture<T>,
        scheduler: ScheduledExecutorService,
        timeoutMillis: Long,
        code: TranscriptionErrorCode,
        message: String,
        onTimeout: () -> Unit = {}
    ): ScheduledFuture<*> = scheduler.schedule({
        if (future.completeExceptionally(TranscriptionFailure(code, message))) {
            // Completion is the ownership boundary. Side effects happen only for the
            // timer that actually won the race against normal completion/cancellation.
            onTimeout()
        }
    }, timeoutMillis, TimeUnit.MILLISECONDS)
}
