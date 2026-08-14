package app.nuvi.android.infrastructure.model

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile

object GgmlModelFileValidator {
    const val MINIMUM_MODEL_BYTES = 10L * 1024L * 1024L
    private val MAGIC = byteArrayOf(0x6c, 0x6d, 0x67, 0x67)

    @Throws(IOException::class)
    fun validate(file: File, displayName: String) {
        if (!displayName.endsWith(".bin", ignoreCase = true)) {
            throw IOException("Select a legacy whisper.cpp GGML .bin model")
        }
        if (!file.isFile || file.length() < MINIMUM_MODEL_BYTES) {
            throw IOException("The selected model is too small or incomplete")
        }
        val header = ByteArray(MAGIC.size)
        RandomAccessFile(file, "r").use { it.readFully(header) }
        if (!header.contentEquals(MAGIC)) {
            throw IOException("The selected file does not have a whisper.cpp GGML header")
        }
    }
}
