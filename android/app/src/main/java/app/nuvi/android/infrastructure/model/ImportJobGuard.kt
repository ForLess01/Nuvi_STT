package app.nuvi.android.infrastructure.model

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException

class ImportJobGuard(private val lockFile: File) {
    fun <T> runExclusive(block: () -> T): T {
        lockFile.parentFile?.mkdirs()
        RandomAccessFile(lockFile, "rw").use { randomAccess ->
            randomAccess.channel.use { channel ->
                val lock: FileLock = try {
                    channel.tryLock()
                } catch (_: OverlappingFileLockException) {
                    null
                } ?: throw IOException("IMPORT_RUNNING: A model import is already running")
                lock.use { return block() }
            }
        }
    }

    fun isLocked(): Boolean {
        lockFile.parentFile?.mkdirs()
        return RandomAccessFile(lockFile, "rw").use { randomAccess ->
            randomAccess.channel.use { channel ->
                val lock = try {
                    channel.tryLock()
                } catch (_: OverlappingFileLockException) {
                    null
                }
                if (lock == null) true else {
                    lock.close()
                    false
                }
            }
        }
    }

    /** Runs maintenance only when no importer owns the job lock. */
    fun <T> runIfIdle(block: () -> T): T? {
        lockFile.parentFile?.mkdirs()
        return RandomAccessFile(lockFile, "rw").use { randomAccess ->
            randomAccess.channel.use { channel ->
                val lock = try {
                    channel.tryLock()
                } catch (_: OverlappingFileLockException) {
                    null
                } ?: return@use null
                lock.use { block() }
            }
        }
    }
}

object OrphanImportCleaner {
    fun cleanCandidate(directory: File, candidateId: String): Int {
        require(SAFE_CANDIDATE.matches(candidateId))
        directory.mkdirs()
        return listOf(
            File(directory, ".import-$candidateId"),
            File(directory, ".import-$candidateId.bin")
        ).count { it.exists() && it.deleteRecursively() }
    }

    private val SAFE_CANDIDATE = Regex("[A-Za-z0-9-]+")
}
