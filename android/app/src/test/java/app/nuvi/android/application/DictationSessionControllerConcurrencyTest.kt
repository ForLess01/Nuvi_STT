package app.nuvi.android.application

import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class DictationSessionControllerConcurrencyTest {
    @Test fun cancelThenImmediateRestartCannotClearOldCancellation() {
        val ownership = RequestOwnership()
        val old = RequestContext.create(1, 0, 100)
        ownership.replace(old)
        ownership.cancelActive()
        val next = RequestContext.create(2, 1, 100)
        ownership.replace(next)
        assertTrue(old.isCancelled)
        assertFalse(next.isCancelled)
        assertTrue(ownership.owns(next))
    }

    @Test fun timeoutThenRestartKeepsTimedOutRequestCancelled() {
        val ownership = RequestOwnership()
        val timedOut = RequestContext.create(1, 0, 100)
        ownership.replace(timedOut)
        timedOut.cancel()
        val restarted = RequestContext.create(2, 1, 100)
        ownership.replace(restarted)
        assertTrue(timedOut.isCancelled)
        assertSame(restarted, ownership.current())
    }

    @Test fun staleRequestCannotOwnReplacement() {
        val ownership = RequestOwnership()
        val stale = RequestContext.create(1, 0, 100)
        val current = RequestContext.create(2, 1, 100)
        ownership.replace(stale)
        ownership.replace(current)
        assertFalse(ownership.owns(stale))
        assertTrue(ownership.owns(current))
    }
}
