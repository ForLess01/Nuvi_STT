package app.nuvi.android.infrastructure.model

import app.nuvi.android.domain.ModelFamily

data class ImportResources(
    val freeStorageBytes: Long,
    val availableMemoryBytes: Long,
    val lowMemory: Boolean,
    val sourceBytes: Long?
)

data class ImportRequirement(val requiredStorageBytes: Long, val requiredMemoryBytes: Long)

object ImportPreflightPolicy {
    private const val MIB = 1024L * 1024L
    private const val STORAGE_HEADROOM = 512L * MIB
    private const val PARAKEET_STAGING = 900L * MIB
    private const val PARAKEET_MEMORY = 1_200L * MIB
    private const val WHISPER_MEMORY = 512L * MIB

    fun requirement(family: ModelFamily, sourceBytes: Long?): ImportRequirement = when (family) {
        ModelFamily.PARAKEET -> ImportRequirement(PARAKEET_STAGING + STORAGE_HEADROOM, PARAKEET_MEMORY)
        ModelFamily.WHISPER -> ImportRequirement((sourceBytes ?: 2_000L * MIB) + STORAGE_HEADROOM, WHISPER_MEMORY)
    }

    fun validate(family: ModelFamily, resources: ImportResources) {
        val requirement = requirement(family, resources.sourceBytes)
        if (resources.freeStorageBytes < requirement.requiredStorageBytes) {
            throw java.io.IOException("STORAGE_LOW: Free at least ${requirement.requiredStorageBytes / MIB} MB before importing")
        }
        validateMemory(family, resources.availableMemoryBytes, resources.lowMemory)
    }

    fun validateMemory(family: ModelFamily, availableMemoryBytes: Long, lowMemory: Boolean) {
        val required = requirement(family, null).requiredMemoryBytes
        if (lowMemory || availableMemoryBytes < required) {
            throw java.io.IOException("MEMORY_PRESSURE: Close other apps and retry the model import")
        }
    }
}
