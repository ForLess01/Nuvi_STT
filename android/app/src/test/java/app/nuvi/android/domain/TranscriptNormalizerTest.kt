package app.nuvi.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

class TranscriptNormalizerTest {
    @Test fun trimsAndCollapsesWhitespace() {
        assertEquals("Hola mundo.", TranscriptNormalizer.normalize("  Hola   mundo. \n"))
    }

    @Test fun removesWhisperSilenceMarkers() {
        assertEquals("", TranscriptNormalizer.normalize(" [BLANK_AUDIO] [NO_SPEECH] "))
    }
}
