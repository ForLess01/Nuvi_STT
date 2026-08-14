package app.nuvi.android.infrastructure.model

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/** Defers deletion of retired model files until every initialization lease closes. */
class ModelLeaseRegistry(private val deleteFile: (File) -> Boolean = { it.deleteRecursively() }) {
    private val counts = mutableMapOf<String, Int>()
    private val files = mutableMapOf<String, File>()
    private val retired = mutableSetOf<String>()

    @Synchronized fun acquire(file: File): Lease {
        val key = file.absoluteFile.normalize().path
        counts[key] = (counts[key] ?: 0) + 1
        files[key] = file
        return Lease(file) { release(key) }
    }

    @Synchronized fun retire(file: File) {
        val key = file.absoluteFile.normalize().path
        if ((counts[key] ?: 0) > 0) {
            files[key] = file
            retired += key
        } else {
            deleteFile(file)
        }
    }

    @Synchronized private fun release(key: String) {
        val remaining = (counts[key] ?: return) - 1
        if (remaining > 0) {
            counts[key] = remaining
            return
        }
        counts.remove(key)
        if (retired.remove(key)) files[key]?.let(deleteFile)
        files.remove(key)
    }

    class Lease internal constructor(val file: File, private val release: () -> Unit) : AutoCloseable {
        private val closed = AtomicBoolean(false)
        override fun close() { if (closed.compareAndSet(false, true)) release() }
    }
}
