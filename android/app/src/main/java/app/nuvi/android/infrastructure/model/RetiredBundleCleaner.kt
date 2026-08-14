package app.nuvi.android.infrastructure.model

import java.io.File

object RetiredBundleCleaner {
    fun clean(directory: File, activeNames: Set<String>, runtimeLeaseNames: Set<String>): Int {
        directory.mkdirs()
        var removed = 0
        directory.listFiles().orEmpty().filter { it.name.startsWith(".retired-") }.forEach { marker ->
            val name = runCatching { marker.readText().trim() }.getOrNull()
            if (name != null && name !in activeNames && name !in runtimeLeaseNames) {
                if (File(directory, name).deleteRecursively()) removed++
                marker.delete()
            }
        }
        directory.listFiles().orEmpty().filter {
            (it.name.startsWith("parakeet-") || it.name.startsWith("whisper-")) &&
                it.name !in activeNames && it.name !in runtimeLeaseNames &&
                !File(directory, ".retired-${it.name}").exists()
        }.forEach { if (it.deleteRecursively()) removed++ }
        return removed
    }
}
