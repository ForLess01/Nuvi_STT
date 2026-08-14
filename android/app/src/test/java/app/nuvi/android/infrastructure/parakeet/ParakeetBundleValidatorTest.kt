package app.nuvi.android.infrastructure.parakeet

import app.nuvi.android.domain.ModelBundle
import java.io.RandomAccessFile
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ParakeetBundleValidatorTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun rejectsIncompleteBundle() {
        val error = runCatching { ParakeetBundleValidator.validate(ModelBundle.Parakeet(temporary.root)) }.exceptionOrNull()
        assertTrue(error?.message.orEmpty().contains("missing"))
    }

    @Test fun acceptsExactRequiredFileSet() {
        RandomAccessFile(temporary.newFile("encoder.int8.onnx"), "rw").use { it.setLength(ParakeetBundleValidator.MIN_ENCODER_BYTES) }
        temporary.newFile("decoder.int8.onnx").writeBytes(byteArrayOf(1))
        temporary.newFile("joiner.int8.onnx").writeBytes(byteArrayOf(1))
        temporary.newFile("tokens.txt").writeText("<blk> 0\n")
        ParakeetBundleValidator.validate(ModelBundle.Parakeet(temporary.root))
    }
}
