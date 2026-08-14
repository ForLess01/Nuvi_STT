package app.nuvi.android.infrastructure.model

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/** Durable queue of exact candidate IDs awaiting staging cleanup. */
class DeferredCandidateCleanup(private val directory: File) {
    fun request(candidateId: String): Boolean = runCatching {
        require(SAFE_CANDIDATE.matches(candidateId))
        directory.mkdirs()
        val target = marker(candidateId)
        if (!target.exists()) {
            val temporary = File(directory, ".$PREFIX$candidateId-${UUID.randomUUID()}")
            try {
                FileOutputStream(temporary).use { output ->
                    output.write(candidateId.toByteArray(Charsets.UTF_8))
                    output.fd.sync()
                }
                Files.move(
                    temporary.toPath(),
                    target.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING
                )
            } finally {
                temporary.delete()
            }
        }
    }.isSuccess

    fun pendingCandidateIds(): Set<String> = directory.listFiles().orEmpty().mapNotNull { file ->
        MARKER.matchEntire(file.name)?.groupValues?.get(1)
    }.toSet()

    fun complete(candidateId: String) {
        marker(candidateId).delete()
    }

    fun hasPending(candidateId: String): Boolean = marker(candidateId).isFile

    private fun marker(candidateId: String) = File(directory, "$PREFIX$candidateId$SUFFIX")

    companion object {
        private const val PREFIX = ".pending-import-cleanup-"
        private const val SUFFIX = ".v1"
        private val SAFE_CANDIDATE = Regex("[A-Za-z0-9-]+")
        private val MARKER = Regex("${Regex.escape(PREFIX)}([A-Za-z0-9-]+)${Regex.escape(SUFFIX)}")
    }
}
