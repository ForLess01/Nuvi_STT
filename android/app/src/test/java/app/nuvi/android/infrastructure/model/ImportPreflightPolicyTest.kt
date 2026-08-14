package app.nuvi.android.infrastructure.model

import app.nuvi.android.domain.ModelFamily
import java.io.IOException
import org.junit.Assert.assertTrue
import org.junit.Test

class ImportPreflightPolicyTest {
    @Test fun lowStorageFailsBeforeExtraction() {
        val error = runCatching {
            ImportPreflightPolicy.validate(ModelFamily.PARAKEET, ImportResources(128L * MIB, 4L * GIB, false, 600L * MIB))
        }.exceptionOrNull() as IOException
        assertTrue(error.message!!.startsWith("STORAGE_LOW:"))
    }

    @Test fun memoryPressureFailsBeforeNativeProbe() {
        val error = runCatching {
            ImportPreflightPolicy.validate(ModelFamily.PARAKEET, ImportResources(4L * GIB, 800L * MIB, false, 600L * MIB))
        }.exceptionOrNull() as IOException
        assertTrue(error.message!!.startsWith("MEMORY_PRESSURE:"))
    }

    @Test fun s24ClassResourcesPass() {
        ImportPreflightPolicy.validate(ModelFamily.PARAKEET, ImportResources(8L * GIB, 5L * GIB, false, 600L * MIB))
    }

    companion object {
        private const val MIB = 1024L * 1024L
        private const val GIB = 1024L * MIB
    }
}
