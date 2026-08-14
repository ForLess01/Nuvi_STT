package app.nuvi.android.presentation

import org.junit.Assert.assertTrue
import org.junit.Test

class SetupLayoutMetricsTest {
    @Test fun heroHasEnoughHeightForDefinedFerrofluidAndCutoutSafeSpacing() {
        assertTrue(SetupLayoutMetrics.HERO_HEIGHT_DP >= 128)
        assertTrue(SetupLayoutMetrics.CONTENT_TOP_PADDING_DP >= 16)
        assertTrue(SetupLayoutMetrics.CONTENT_HORIZONTAL_PADDING_DP >= 16)
    }
}
