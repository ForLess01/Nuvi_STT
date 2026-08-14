package app.nuvi.android.application

import org.junit.Assert.assertEquals
import org.junit.Test

class LatestValueDispatcherTest {
    @Test fun burstSchedulesOneCallbackAndDeliversLatestState() {
        val scheduled = ArrayDeque<() -> Unit>()
        val received = mutableListOf<Int>()
        val dispatcher = LatestValueDispatcher<Int>(scheduled::addLast, received::add)

        repeat(10_000) { dispatcher.offer(it) }
        assertEquals(1, scheduled.size)
        scheduled.removeFirst().invoke()
        assertEquals(listOf(9_999), received)
        assertEquals(0, scheduled.size)
    }

    @Test fun updateDuringDeliveryIsNeverReorderedBehindSuccess() {
        val scheduled = ArrayDeque<() -> Unit>()
        val received = mutableListOf<String>()
        lateinit var dispatcher: LatestValueDispatcher<String>
        dispatcher = LatestValueDispatcher(scheduled::addLast) { value ->
            received += value
            if (value == "running") dispatcher.offer("success")
        }
        dispatcher.offer("running")
        while (scheduled.isNotEmpty()) scheduled.removeFirst().invoke()
        assertEquals(listOf("running", "success"), received)
    }
}
