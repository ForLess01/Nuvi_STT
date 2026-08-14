package app.nuvi.android.infrastructure.asr

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.Rule

class RuntimeLeaseFileTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun liveRuntimeLeaseProtectsExactBundle() {
        val lease = RuntimeLeaseFile(temporary.root) { it == 42 }
        lease.write(42, "v1", File(temporary.root, "parakeet-v1"))
        assertEquals("parakeet-v1", lease.leasedRootName())
        lease.clear(42)
        assertTrue(temporary.root.listFiles().orEmpty().none { it.name.startsWith("asr-runtime-lease-") })
    }

    @Test fun stalePidRemovesLease() {
        val lease = RuntimeLeaseFile(temporary.root) { false }
        lease.write(99, "v1", File(temporary.root, "parakeet-v1"))
        assertNull(lease.leasedRootName())
        assertTrue(temporary.root.listFiles().orEmpty().none { it.name.startsWith("asr-runtime-lease-") })
    }
}
