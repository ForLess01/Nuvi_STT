package app.nuvi.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

class TranscriptionTimingTest {
    @Test fun shortAudioGetsTwentySecondMinimum() {
        assertEquals(20_000L, TranscriptionTiming.inferenceDeadlineMillis(16_000))
    }

    @Test fun longAudioIsCappedAtNinetySeconds() {
        assertEquals(90_000L, TranscriptionTiming.inferenceDeadlineMillis(16_000 * 120))
    }

    @Test fun normalAudioGetsThreeTimesRealTime() {
        assertEquals(60_000L, TranscriptionTiming.inferenceDeadlineMillis(16_000 * 20))
    }
}
