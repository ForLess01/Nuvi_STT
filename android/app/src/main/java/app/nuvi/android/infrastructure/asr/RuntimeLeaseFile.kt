package app.nuvi.android.infrastructure.asr

import java.io.File

class RuntimeLeaseFile(
    private val directory: File,
    private val pidAlive: (Int) -> Boolean = { File("/proc/$it").exists() }
) {
    fun write(pid: Int, version: String, root: File) {
        directory.mkdirs()
        val target = target(pid)
        val temporary = File(directory, ".asr-lease-$pid-${System.nanoTime()}")
        temporary.writeText("$pid\n$version\n${root.name}\n")
        if (!temporary.renameTo(target)) {
            target.delete()
            check(temporary.renameTo(target))
        }
    }

    fun leasedRootNames(): Set<String> = directory.listFiles().orEmpty()
        .filter { it.name.startsWith(PREFIX) && it.name.endsWith(SUFFIX) }
        .mapNotNull { target ->
            val lines = runCatching { target.readLines() }.getOrNull() ?: return@mapNotNull null
            val pid = lines.getOrNull(0)?.toIntOrNull() ?: return@mapNotNull null
            if (!pidAlive(pid)) {
                target.delete()
                return@mapNotNull null
            }
            lines.getOrNull(2)
        }
        .toSet()

    fun leasedRootName(): String? = leasedRootNames().firstOrNull()

    fun clear(pid: Int) {
        target(pid).delete()
    }

    private fun target(pid: Int) = File(directory, "$PREFIX$pid$SUFFIX")

    companion object {
        private const val PREFIX = "asr-runtime-lease-"
        private const val SUFFIX = ".v1"
    }
}
