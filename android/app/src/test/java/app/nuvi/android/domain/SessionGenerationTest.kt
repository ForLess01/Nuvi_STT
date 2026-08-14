package app.nuvi.android.domain

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionGenerationTest {
    @Test fun newerGenerationInvalidatesEarlierAsyncResult() {
        val generations = SessionGeneration()
        val first = generations.next()
        assertTrue(generations.isCurrent(first))
        val second = generations.next()
        assertFalse(generations.isCurrent(first))
        assertTrue(generations.isCurrent(second))
    }
}
