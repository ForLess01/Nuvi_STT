package app.nuvi.android.infrastructure.asr

import app.nuvi.android.domain.ModelFamily
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineCachePolicyTest {
    @Test fun exactBundleIdentityReusesLoadedEngine() {
        assertTrue(EngineCachePolicy.canReuse(
            ModelFamily.PARAKEET, File("/models/parakeet-a"), "parakeet-a",
            ModelFamily.PARAKEET, File("/models/parakeet-a"), "parakeet-a"
        ))
    }

    @Test fun familyVersionOrRootChangeInvalidatesCache() {
        assertFalse(EngineCachePolicy.canReuse(
            ModelFamily.PARAKEET, File("/models/parakeet-a"), "parakeet-a",
            ModelFamily.PARAKEET, File("/models/parakeet-b"), "parakeet-b"
        ))
        assertFalse(EngineCachePolicy.canReuse(
            ModelFamily.PARAKEET, File("/models/same"), "same",
            ModelFamily.WHISPER, File("/models/same"), "same"
        ))
    }
}
