package app.nuvi.android.application

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Coalesces any burst into at most one scheduled callback while preserving the latest value. */
class LatestValueDispatcher<T>(
    private val schedule: (() -> Unit) -> Unit,
    private val consumer: (T) -> Unit
) {
    private val latest = AtomicReference<T?>(null)
    private val scheduled = AtomicBoolean(false)

    fun offer(value: T) {
        latest.set(value)
        scheduleIfNeeded()
    }

    private fun scheduleIfNeeded() {
        if (scheduled.compareAndSet(false, true)) schedule(::drain)
    }

    private fun drain() {
        latest.getAndSet(null)?.let(consumer)
        scheduled.set(false)
        if (latest.get() != null) scheduleIfNeeded()
    }
}
