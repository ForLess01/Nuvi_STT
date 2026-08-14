package app.nuvi.android.infrastructure.parakeet

import app.nuvi.android.domain.ModelBundle
import java.io.IOException

object ParakeetBundleValidator {
    val REQUIRED_FILES = setOf("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt")
    const val MIN_ENCODER_BYTES = 100L * 1024L * 1024L
    const val MAX_BUNDLE_BYTES = 900L * 1024L * 1024L

    @Throws(IOException::class)
    fun validate(bundle: ModelBundle.Parakeet) {
        val files = listOf(bundle.encoder, bundle.decoder, bundle.joiner, bundle.tokens)
        if (!bundle.root.isDirectory || files.any { !it.isFile || it.length() <= 0L }) {
            throw IOException("Parakeet bundle is missing one or more required files")
        }
        if (bundle.encoder.length() < MIN_ENCODER_BYTES) throw IOException("Parakeet encoder is unexpectedly small")
        val total = files.sumOf { it.length() }
        if (total > MAX_BUNDLE_BYTES) throw IOException("Parakeet bundle exceeds the 900 MB safety limit")
        if (bundle.tokens.length() > 2L * 1024L * 1024L) throw IOException("tokens.txt exceeds 2 MB")
        val hasToken = bundle.tokens.bufferedReader().use { reader ->
            var consumed = 0
            var valid = false
            while (consumed <= 8_192) {
                val line = reader.readLine() ?: break
                consumed += line.length + 1
                if (line.isNotBlank()) { valid = true; break }
            }
            valid
        }
        if (!hasToken) throw IOException("tokens.txt is empty or invalid")
    }
}
