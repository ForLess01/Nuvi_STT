package app.nuvi.android.infrastructure.whisper

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CancellationWatcherTest {
    @Test fun closeJoinsWatcherBeforeEngineCouldBeDestroyed() {
        val cancellation = AtomicBoolean(false)
        var calls = 0
        val watcher = CancellationWatcher(cancellation, { calls++ })
        watcher.close()
        cancellation.set(true)
        Thread.sleep(40)
        assertEquals(0, calls)
    }

    @Test fun cancellationCallbackCompletesBeforeCloseReturns() {
        val cancellation = AtomicBoolean(false)
        val called = CountDownLatch(1)
        val watcher = CancellationWatcher(cancellation, called::countDown)
        cancellation.set(true)
        assertTrue(called.await(1, TimeUnit.SECONDS))
        watcher.close()
    }

    @Test fun preInterruptedCallerStillWaitsForDelayedWatcherAndRestoresInterrupt() {
        val cancellation = AtomicBoolean(true)
        val started = CountDownLatch(1)
        val finished = AtomicBoolean(false)
        val watcher = CancellationWatcher(cancellation, {
            started.countDown()
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(80)
            while (System.nanoTime() < deadline) { /* Deliberately ignore interruption. */ }
            finished.set(true)
        }, joinMillis = 5)
        assertTrue(started.await(1, TimeUnit.SECONDS))
        Thread.currentThread().interrupt()

        watcher.close()

        assertTrue(finished.get())
        assertTrue(!watcher.isAliveForTesting())
        assertTrue(Thread.currentThread().isInterrupted)
        Thread.interrupted() // Do not leak interrupt status into the JUnit worker.
    }
}
