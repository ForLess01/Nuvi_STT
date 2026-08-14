package app.nuvi.android.infrastructure.model

import app.nuvi.android.infrastructure.parakeet.ParakeetBundleValidator
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream

object ParakeetArchiveExtractor {
    const val MAX_ENTRIES = 64
    const val MAX_TOTAL_BYTES = 900L * 1024L * 1024L
    const val MAX_AUXILIARY_BYTES = 64L * 1024L * 1024L
    val FILE_CAPS = mapOf(
        "encoder.int8.onnx" to 800L * 1024L * 1024L,
        "decoder.int8.onnx" to 32L * 1024L * 1024L,
        "joiner.int8.onnx" to 16L * 1024L * 1024L,
        "tokens.txt" to 2L * 1024L * 1024L
    )
    enum class EntryAction { REQUIRED, AUXILIARY, DIRECTORY }
    data class Budget(var entries: Int = 0, var total: Long = 0, var auxiliary: Long = 0, val required: MutableSet<String> = mutableSetOf())

    class HardLimitInputStream(input: InputStream, private val maximumBytes: Long = MAX_TOTAL_BYTES) : java.io.FilterInputStream(input) {
        private var consumed = 0L
        override fun read(): Int = super.read().also { if (it >= 0) add(1) }
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
            super.read(buffer, offset, length).also { if (it > 0) add(it.toLong()) }
        override fun skip(count: Long): Long = super.skip(count).also { if (it > 0) add(it) }
        private fun add(count: Long) {
            consumed += count
            if (consumed > maximumBytes) throw invalid("decompressed stream exceeds ${maximumBytes / (1024 * 1024)} MB")
        }
    }

    fun inspectEntry(budget: Budget, rawEntryName: String, size: Long, isFile: Boolean, isDirectory: Boolean): EntryAction {
        if (++budget.entries > MAX_ENTRIES) throw invalid("archive contains too many entries")
        val rawName = rawEntryName.replace('\\', '/')
        if (rawName.startsWith("/") || rawName.split('/').any { it == ".." }) throw invalid("unsafe archive path")
        if (isDirectory) {
            if (size != 0L) throw invalid("directory entries must have zero size")
            return EntryAction.DIRECTORY
        }
        if (!isFile) throw invalid("links and special entries are not allowed")
        if (size <= 0L) throw invalid("empty archive entry")
        budget.total += size
        if (budget.total > MAX_TOTAL_BYTES) throw invalid("decompressed archive exceeds 900 MB")
        val basename = rawName.substringAfterLast('/')
        val requiredCap = FILE_CAPS[basename]
        if (requiredCap != null) {
            if (!budget.required.add(basename)) throw invalid("duplicate $basename")
            if (size > requiredCap) throw invalid("$basename exceeds its size limit")
            return EntryAction.REQUIRED
        }
        val allowedAuxiliary = basename.equals("README.md", true) && size <= 1024L * 1024L ||
            rawName.contains("/test_wavs/") && basename.endsWith(".wav", true) && size <= 32L * 1024L * 1024L
        if (!allowedAuxiliary) throw invalid("unexpected file $basename")
        budget.auxiliary += size
        if (budget.auxiliary > MAX_AUXILIARY_BYTES) throw invalid("auxiliary files exceed 64 MB")
        return EntryAction.AUXILIARY
    }

    fun extract(
        input: InputStream,
        staging: File,
        onProgress: (Int) -> Unit = {},
        isCancelled: () -> Boolean = { false }
    ) {
        staging.mkdirs()
        val boundedCompressed = HardLimitInputStream(input, MAX_TOTAL_BYTES)
        val decompressed = BZip2CompressorInputStream(BufferedInputStream(boundedCompressed), true)
        TarArchiveInputStream(HardLimitInputStream(decompressed)).use { tar ->
            val budget = Budget()
            while (true) {
                checkCancelled(isCancelled)
                val entry = tar.nextEntry ?: break
                val rawName = entry.name.replace('\\', '/')
                val basename = rawName.substringAfterLast('/')
                when (inspectEntry(budget, rawName, entry.size, entry.isFile, entry.isDirectory)) {
                    EntryAction.DIRECTORY -> continue
                    EntryAction.REQUIRED -> {
                    copyExact(tar, File(staging, basename), entry.size, isCancelled) { written ->
                        onProgress(((budget.required.size - 1) * 20 + written * 20 / entry.size).toInt().coerceAtMost(85))
                    }
                    }
                    EntryAction.AUXILIARY -> drainExact(tar, entry.size, isCancelled)
                }
            }
            if (budget.required != ParakeetBundleValidator.REQUIRED_FILES) throw invalid("expected encoder, decoder, joiner, and tokens")
        }
    }

    private fun copyExact(
        input: InputStream,
        outputFile: File,
        size: Long,
        isCancelled: () -> Boolean,
        progress: (Long) -> Unit
    ) {
        FileOutputStream(outputFile).use { output ->
            val buffer = ByteArray(128 * 1024)
            var written = 0L
            while (written < size) {
                checkCancelled(isCancelled)
                val read = input.read(buffer, 0, minOf(buffer.size.toLong(), size - written).toInt())
                if (read < 0) throw invalid("truncated ${outputFile.name}")
                output.write(buffer, 0, read)
                written += read
                progress(written)
            }
            output.fd.sync()
        }
    }

    private fun drainExact(input: InputStream, size: Long, isCancelled: () -> Boolean) {
        val buffer = ByteArray(64 * 1024)
        var readTotal = 0L
        while (readTotal < size) {
            checkCancelled(isCancelled)
            val read = input.read(buffer, 0, minOf(buffer.size.toLong(), size - readTotal).toInt())
            if (read < 0) throw invalid("truncated auxiliary entry")
            readTotal += read
        }
    }

    private fun checkCancelled(isCancelled: () -> Boolean) {
        if (isCancelled()) throw ImportCancelledException()
    }

    private fun invalid(message: String) = IOException("MODEL_INVALID: $message")
}
