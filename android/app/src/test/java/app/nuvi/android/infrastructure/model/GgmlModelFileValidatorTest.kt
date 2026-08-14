package app.nuvi.android.infrastructure.model

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class GgmlModelFileValidatorTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun acceptsSizedLegacyGgmlBinHeader() {
        val file = modelFile(byteArrayOf(0x6c, 0x6d, 0x67, 0x67))
        GgmlModelFileValidator.validate(file, "ggml-base-q5_1.bin")
    }

    @Test fun rejectsWrongExtensionAndHeader() {
        val file = modelFile(byteArrayOf(0, 0, 0, 0))
        assertThrows(IOException::class.java) { GgmlModelFileValidator.validate(file, "model.gguf") }
        assertThrows(IOException::class.java) { GgmlModelFileValidator.validate(file, "model.bin") }
    }

    private fun modelFile(header: ByteArray): File = temporary.newFile().also { file ->
        RandomAccessFile(file, "rw").use {
            it.write(header)
            it.setLength(GgmlModelFileValidator.MINIMUM_MODEL_BYTES)
        }
    }
}
