package app.nuvi.android.infrastructure.model

import app.nuvi.android.domain.ModelFamily
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Base64
import java.util.UUID

enum class ImportStage(val terminal: Boolean = false) {
    PREFLIGHT,
    EXTRACTING,
    COPYING,
    STRUCTURAL_VALIDATION,
    NATIVE_PROBE,
    ACTIVATING,
    COMPLETE(true),
    FAILED(true),
    CANCELLED(true),
    INTERRUPTED(true)
}

data class ImportJournal(
    val family: ModelFamily,
    val sourceLabel: String,
    val sourceId: String,
    val stage: ImportStage,
    val percent: Int,
    val startedAtMs: Long,
    val updatedAtMs: Long,
    val candidateId: String,
    val errorCode: String? = null,
    val sizeMb: Long? = null,
    val stageStartedAtMs: Long = updatedAtMs,
    /** V1 codec compatibility only; native initialization exposes no progress heartbeat. */
    val heartbeatAtMs: Long = updatedAtMs,
    val workerPid: Int? = null
) {
    val isActive: Boolean get() = !stage.terminal

    fun advance(stage: ImportStage, percent: Int, nowMs: Long): ImportJournal = copy(
        stage = stage,
        percent = percent.coerceIn(0, 100),
        updatedAtMs = nowMs,
        stageStartedAtMs = if (this.stage == stage) stageStartedAtMs else nowMs
    )
}

/** Atomic, process-safe persistence. The source id is an opaque hash, never a filesystem path. */
class ImportJournalStore(private val directory: File) {
    private val journal = File(directory, "import-journal.v1")
    private val lockFile = File(directory, "import-journal.lock")

    fun read(): ImportJournal? = runCatching {
        if (!journal.isFile) return null
        ImportJournalCodec.decode(journal.readText(Charsets.UTF_8))
    }.getOrNull()

    /** Cross-process, first-terminal-wins journal update. */
    fun write(value: ImportJournal): ImportJournal {
        directory.mkdirs()
        return RandomAccessFile(lockFile, "rw").use { lock ->
            lock.channel.lock().use {
                val current = read()
                if (current?.candidateId == value.candidateId && current.stage.terminal) return@use current
                if (current != null && current.candidateId != value.candidateId) {
                    // Only a fresh preflight may replace a previous candidate. Late callbacks
                    // from a killed worker can never overwrite the newer import's journal.
                    if (value.stage != ImportStage.PREFLIGHT || current.isActive) return@use current
                }
                val temporary = File(directory, ".import-journal-${value.candidateId}-${UUID.randomUUID()}")
                FileOutputStream(temporary).use { output ->
                    output.write(ImportJournalCodec.encode(value).toByteArray(Charsets.UTF_8))
                    output.fd.sync()
                }
                Files.move(
                    temporary.toPath(),
                    journal.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING
                )
                value
            }
        }
    }

    fun recoverInterrupted(nowMs: Long, activeProcessOwnsJob: Boolean): ImportJournal? {
        val current = read() ?: return null
        if (!current.isActive || activeProcessOwnsJob) return current
        val recovered = current.copy(
            stage = ImportStage.INTERRUPTED,
            updatedAtMs = nowMs,
            errorCode = "IMPORT_INTERRUPTED"
        )
        return write(recovered)
    }
}

object ImportJournalCodec {
    private fun encodeText(value: String): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(value.toByteArray(Charsets.UTF_8))

    private fun decodeText(value: String): String =
        String(Base64.getUrlDecoder().decode(value), Charsets.UTF_8)

    fun encode(value: ImportJournal): String = listOf(
        value.family.name,
        encodeText(value.sourceLabel),
        encodeText(value.sourceId),
        value.stage.name,
        value.percent.coerceIn(0, 100).toString(),
        value.startedAtMs.toString(),
        value.updatedAtMs.toString(),
        value.candidateId,
        encodeText(value.errorCode.orEmpty()),
        value.sizeMb?.toString().orEmpty(),
        value.stageStartedAtMs.toString(),
        value.heartbeatAtMs.toString(),
        value.workerPid?.toString().orEmpty()
    ).joinToString("\n")

    fun decode(raw: String): ImportJournal {
        val fields = raw.lineSequence().toList()
        require(fields.size == 10 || fields.size == 13) { "Unsupported import journal" }
        return ImportJournal(
            family = ModelFamily.valueOf(fields[0]),
            sourceLabel = decodeText(fields[1]),
            sourceId = decodeText(fields[2]),
            stage = ImportStage.valueOf(fields[3]),
            percent = fields[4].toInt().coerceIn(0, 100),
            startedAtMs = fields[5].toLong(),
            updatedAtMs = fields[6].toLong(),
            candidateId = fields[7],
            errorCode = decodeText(fields[8]).ifBlank { null },
            sizeMb = fields[9].takeIf(String::isNotBlank)?.toLong(),
            stageStartedAtMs = fields.getOrNull(10)?.toLongOrNull() ?: fields[6].toLong(),
            heartbeatAtMs = fields.getOrNull(11)?.toLongOrNull() ?: fields[6].toLong(),
            workerPid = fields.getOrNull(12)?.takeIf(String::isNotBlank)?.toInt()
        )
    }
}

class ImportCancelledException : java.io.IOException("IMPORT_CANCELLED: Model import cancelled")
