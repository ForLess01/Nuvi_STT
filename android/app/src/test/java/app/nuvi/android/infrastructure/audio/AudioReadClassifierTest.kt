package app.nuvi.android.infrastructure.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioReadClassifierTest {
    @Test fun recognizesDataAndZeroLengthRetry() {
        assertEquals(AudioReadOutcome.Data(4), AudioReadClassifier.classify(4, 8))
        assertEquals(AudioReadOutcome.Retry, AudioReadClassifier.classify(0, 8))
    }

    @Test fun everyNegativeAudioRecordCodeIsTerminal() {
        listOf(-1, -2, -3, -6).forEach { code ->
            val result = AudioReadClassifier.classify(code, 8)
            assertTrue(result is AudioReadOutcome.Failure)
            assertEquals(code, (result as AudioReadOutcome.Failure).code)
        }
    }
}
