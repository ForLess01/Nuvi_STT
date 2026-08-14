package app.nuvi.android.infrastructure.asr

import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock

/** Bounded local diagnostics. It intentionally has no field for audio or transcript text. */
class LocalAsrDiagnostics(private val directory: File) {
    data class Entry(
        val requestId: String,
        val stage: String,
        val family: String,
        val bundleVersion: String,
        val pid: Int,
        val causeClass: String = "",
        val loadMillis: Long = 0,
        val decodeMillis: Long = 0
    )

    fun append(entry: Entry): Boolean = runCatching {
        check(directory.mkdirs() || directory.isDirectory)
        RandomAccessFile(File(directory, "diagnostics.lock"), "rw").use { lockFile ->
            lockFile.channel.lock().use {
                val target = File(directory, "asr-diagnostics.v1")
                val lines = if (target.isFile) target.readLines().takeLast(MAX_LINES - 1) else emptyList()
                val safe = encode(entry)
                val temporary = File(directory, ".diagnostics-${entry.requestId.hashCode()}-${System.nanoTime()}")
                temporary.writeText((lines + safe).joinToString("\n", postfix = "\n"))
                if (!temporary.renameTo(target)) {
                    target.delete()
                    check(temporary.renameTo(target)) { "Unable to persist ASR diagnostics" }
                }
            }
        }
    }.isSuccess

    internal fun encode(entry: Entry): String = listOf(
        entry.requestId,
        entry.stage,
        entry.family,
        entry.bundleVersion,
        entry.pid.toString(),
        entry.causeClass,
        entry.loadMillis.toString(),
        entry.decodeMillis.toString()
    ).joinToString("\t") { sanitize(it) }

    private fun sanitize(value: String): String = value
        .replace(Regex("[^A-Za-z0-9._:-]"), "_")
        .take(160)

    companion object { const val MAX_LINES = 128 }
}
