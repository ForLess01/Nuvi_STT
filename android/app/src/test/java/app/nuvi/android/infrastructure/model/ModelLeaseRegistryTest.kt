package app.nuvi.android.infrastructure.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ModelLeaseRegistryTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun pointerSwapCannotDeleteOldModelWhileInitializationLeaseIsOpen() {
        val oldModel = temporary.newFile("model-old.bin")
        val newModel = temporary.newFile("model-new.bin")
        val registry = ModelLeaseRegistry()
        val oldLease = registry.acquire(oldModel)

        registry.retire(oldModel) // Equivalent to atomically pointing at newModel.

        assertTrue(oldModel.exists())
        assertTrue(newModel.exists())
        oldLease.close()
        assertFalse(oldModel.exists())
        assertTrue(newModel.exists())
    }
}
