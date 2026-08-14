package app.nuvi.android.infrastructure.parakeet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ParakeetFilesystemLoadingContractTest {
    @Test fun importedAbsolutePathsNeverUseAssetManagerLoading() {
        var receivedAssetManager: String? = "unexpected"

        val result = ImportedModelFactory.create<String, String, String>("config") { assets, config ->
            receivedAssetManager = assets
            "constructed:$config"
        }

        assertNull(receivedAssetManager)
        assertEquals("constructed:config", result)
    }
}
