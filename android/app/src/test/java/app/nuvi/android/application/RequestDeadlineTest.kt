package app.nuvi.android.application

import app.nuvi.android.domain.TranscriptionErrorCode
import app.nuvi.android.domain.TranscriptionFailure
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RequestDeadlineTest {
    @Test fun captureTimeoutCompletesWithTypedFailure() {
        val scheduler = Executors.newSingleThreadScheduledExecutor()
        val future = CompletableFuture<String>()
        RequestDeadline.arm(future, scheduler, 5, TranscriptionErrorCode.CAPTURE_TIMEOUT, "capture")
        val error = runCatching { future.get(1, TimeUnit.SECONDS) }.exceptionOrNull()!!.cause as TranscriptionFailure
        assertEquals(TranscriptionErrorCode.CAPTURE_TIMEOUT, error.code)
        scheduler.shutdownNow()
    }

    @Test fun engineTimeoutRunsCancellationAction() {
        val scheduler = Executors.newSingleThreadScheduledExecutor()
        val future = CompletableFuture<String>()
        var cancelled = false
        RequestDeadline.arm(future, scheduler, 5, TranscriptionErrorCode.ENGINE_TIMEOUT, "engine") { cancelled = true }
        runCatching { future.get(1, TimeUnit.SECONDS) }
        assertTrue(cancelled)
        scheduler.shutdownNow()
    }

    @Test fun completedRequestDoesNotTimeOut() {
        val scheduler = Executors.newSingleThreadScheduledExecutor()
        val future = CompletableFuture.completedFuture("ok")
        var cancelled = false
        RequestDeadline.arm(future, scheduler, 5, TranscriptionErrorCode.ENGINE_TIMEOUT, "engine") { cancelled = true }
        Thread.sleep(20)
        assertFalse(cancelled)
        scheduler.shutdownNow()
    }
}
