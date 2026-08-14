package app.nuvi.android.application

import app.nuvi.android.infrastructure.audio.AudioCaptureHandle
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureOwnershipTest {
    @Test fun stopRequestsMicrophoneBeforeQueuedInferenceCanRun() {
        val executor = Executors.newSingleThreadExecutor()
        val releaseQueue = CountDownLatch(1)
        executor.execute { releaseQueue.await() }
        val handle = FakeHandle()
        val ownership = CaptureOwnership().apply { attach(1, handle) }
        var inferenceRan = false

        ownership.stop(1)!!.thenRunAsync({ inferenceRan = true }, executor)

        assertTrue(handle.stopRequested)
        assertFalse(inferenceRan)
        handle.completion.complete(shortArrayOf(1))
        assertFalse(inferenceRan)
        releaseQueue.countDown()
        executor.shutdown()
        assertTrue(executor.awaitTermination(1, TimeUnit.SECONDS))
        assertTrue(inferenceRan)
    }

    @Test fun oldCompletionCannotCancelOrStopRestartedHandle() {
        val ownership = CaptureOwnership()
        val old = FakeHandle()
        val current = FakeHandle()
        ownership.attach(1, old)
        ownership.stop(1)
        ownership.attach(2, current)

        old.completion.complete(shortArrayOf(9))

        assertFalse(current.stopRequested)
        assertFalse(current.cancelled)
        ownership.cancel()
        assertTrue(current.cancelled)
        assertFalse(old.cancelled)
    }

    @Test fun callerCannotPublishTranscribingBeforeStopRequestReturns() {
        val events = mutableListOf<String>()
        val handle = FakeHandle(onStop = { events += "stop-requested" })
        val ownership = CaptureOwnership().apply { attach(7, handle) }

        ownership.stop(7)
        events += "transcribing"

        assertEquals(listOf("stop-requested", "transcribing"), events)
    }

    private class FakeHandle(private val onStop: () -> Unit = {}) : AudioCaptureHandle {
        val completion = CompletableFuture<ShortArray>()
        var stopRequested = false
        var cancelled = false
        override val isCapturing: Boolean get() = !stopRequested && !cancelled
        override fun start() = Unit
        override fun requestStop(): CompletableFuture<ShortArray> {
            stopRequested = true
            onStop()
            return completion
        }
        override fun cancel() { cancelled = true }
    }
}
