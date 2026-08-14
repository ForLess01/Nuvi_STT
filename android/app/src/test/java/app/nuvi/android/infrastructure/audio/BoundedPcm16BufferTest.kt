package app.nuvi.android.infrastructure.audio

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BoundedPcm16BufferTest {
    @Test fun capsSamplesAtConfiguredLimit() {
        val buffer = BoundedPcm16Buffer(3)
        assertFalse(buffer.append(shortArrayOf(1, 2), 2))
        assertTrue(buffer.append(shortArrayOf(3, 4), 2))
        assertArrayEquals(shortArrayOf(1, 2, 3), buffer.take())
    }

    @Test fun discardIsCheapAndLeavesNoSnapshot() {
        val buffer = BoundedPcm16Buffer(2)
        buffer.append(shortArrayOf(7, 8), 2)
        buffer.discard()
        assertFalse(buffer.hasSamples())
        assertArrayEquals(shortArrayOf(), buffer.take())
    }

    @Test fun staleWriterOwnsNoReferenceToNewCaptureBuffer() {
        val oldCapture = BoundedPcm16Buffer(2)
        val newCapture = BoundedPcm16Buffer(2)
        oldCapture.append(shortArrayOf(1), 1)
        newCapture.append(shortArrayOf(9), 1)

        oldCapture.append(shortArrayOf(2), 1)

        assertArrayEquals(shortArrayOf(9), newCapture.take())
        assertArrayEquals(shortArrayOf(1, 2), oldCapture.take())
    }
}
