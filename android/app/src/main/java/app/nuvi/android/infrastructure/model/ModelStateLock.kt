package app.nuvi.android.infrastructure.model

import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock

/** Serializes pointer, runtime-lease, activation-recovery, and cleanup transitions. */
class ModelStateLock(directory: File) {
    private val lockFile = File(directory, "activation.lock")
    private val localLock = localLocks.computeIfAbsent(lockFile.absoluteFile.normalize().path) { ReentrantLock() }

    fun <T> withExclusive(block: () -> T): T {
        localLock.lock()
        try {
            lockFile.parentFile?.mkdirs()
            return RandomAccessFile(lockFile, "rw").use { file ->
                file.channel.use { channel -> channel.lock().use { block() } }
            }
        } finally {
            localLock.unlock()
        }
    }

    companion object {
        private val localLocks = ConcurrentHashMap<String, ReentrantLock>()
    }
}
