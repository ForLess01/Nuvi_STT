package app.nuvi.android.infrastructure.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RetiredBundleCleanerTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun removesRetiredAndOrphanButPreservesActiveAndRuntimeLease() {
        val active = temporary.newFolder("parakeet-active")
        val leased = temporary.newFolder("parakeet-leased")
        val retired = temporary.newFolder("parakeet-retired")
        val orphan = temporary.newFolder("whisper-orphan")
        temporary.newFile(".retired-${retired.name}").writeText(retired.name)

        RetiredBundleCleaner.clean(temporary.root, setOf(active.name), setOf(leased.name))

        assertTrue(active.exists())
        assertTrue(leased.exists())
        assertFalse(retired.exists())
        assertFalse(orphan.exists())
    }
}
