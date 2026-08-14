package app.nuvi.android.infrastructure.model

import app.nuvi.android.domain.ModelBundle
import app.nuvi.android.domain.ModelFamily
import app.nuvi.android.domain.ModelSnapshot
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/** Tiny immutable-pointer reads intentionally independent from heavyweight import serialization. */
class ModelStatusIndex(private val directory: File) {
    private val selectedPointer = File(directory, "selected-family")
    private val activationJournal = File(directory, "activation-journal.v1")
    private val stateLock = ModelStateLock(directory)

    val selectedFamily: ModelFamily
        get() = runCatching {
            ModelFamily.valueOf(selectedPointer.takeIf(File::isFile)?.readText()?.trim() ?: ModelFamily.PARAKEET.name)
        }.getOrDefault(ModelFamily.PARAKEET)

    val activeBundle: ModelBundle? get() = bundleFor(selectedFamily)
    val hasModel: Boolean get() = activeBundle != null

    /** A family and its pointer are accepted only if the selected family stayed stable. */
    fun snapshot(): ModelSnapshot? {
        repeat(3) {
            val before = selectedFamily
            val bundle = bundleFor(before) ?: return null
            val after = selectedFamily
            if (before == after) return ModelSnapshot(before, bundle, bundle.root.name)
        }
        return null
    }

    fun selectFamily(family: ModelFamily) = stateLock.withExclusive { selectFamilyUnlocked(family) }

    /** Publishes a lease while cleanup is excluded from observing an unleased snapshot. */
    fun <T> withSnapshotLease(publish: (ModelSnapshot) -> T): T? = stateLock.withExclusive {
        snapshot()?.let(publish)
    }

    fun <T> withStateLock(block: () -> T): T = stateLock.withExclusive(block)

    fun bundleFor(family: ModelFamily): ModelBundle? {
        val name = activeName(family) ?: return null
        val target = File(directory, name)
        return when (family) {
            ModelFamily.PARAKEET -> ModelBundle.Parakeet(target).takeIf {
                target.isDirectory && it.encoder.isFile && it.decoder.isFile && it.joiner.isFile && it.tokens.isFile
            }
            ModelFamily.WHISPER -> ModelBundle.Whisper(target).takeIf {
                target.isFile && target.length() >= GgmlModelFileValidator.MINIMUM_MODEL_BYTES
            }
        }
    }

    fun activeName(family: ModelFamily): String? {
        val name = runCatching { pointerFor(family).takeIf(File::isFile)?.readText()?.trim() }.getOrNull()
        return name?.takeIf(SAFE_NAME::matches)
    }

    fun replacePointer(family: ModelFamily, name: String, id: String) {
        stateLock.withExclusive { replacePointerUnlocked(family, name, id) }
    }

    private fun replacePointerUnlocked(family: ModelFamily, name: String, id: String) {
        require(SAFE_NAME.matches(name))
        atomicWrite(pointerFor(family), name, "active-$id")
    }

    fun activateTransactional(
        family: ModelFamily,
        name: String,
        id: String,
        onReplaced: (File?) -> Unit = {}
    ) = stateLock.withExclusive {
        activateUnlocked(family, name, id, onReplaced)
    }

    /** Makes a validated candidate visible and activates it without an orphan window. */
    fun publishAndActivateTransactional(
        family: ModelFamily,
        name: String,
        id: String,
        publish: () -> Unit,
        onReplaced: (File?) -> Unit = {}
    ) = stateLock.withExclusive {
        require(SAFE_NAME.matches(name))
        publish()
        activateUnlocked(family, name, id, onReplaced)
    }

    private fun activateUnlocked(
        family: ModelFamily,
        name: String,
        id: String,
        onReplaced: (File?) -> Unit
    ) {
        require(SAFE_NAME.matches(name))
        val previous = bundleFor(family)?.root
        atomicWrite(activationJournal, listOf(family.name, name, id).joinToString("\n"), "activation-$id")
        replacePointerUnlocked(family, name, id)
        selectFamilyUnlocked(family)
        activationJournal.delete()
        onReplaced(previous?.takeIf { it.name != name })
    }

    fun recoverActivation(): Boolean = stateLock.withExclusive { recoverActivationUnlocked() }

    /** Recovers a pending publication before deciding whether its candidate may be deleted. */
    fun deleteCandidateIfUnpublished(candidate: File): Boolean = stateLock.withExclusive {
        if (pendingActivationName() == candidate.name) recoverActivationUnlocked()
        val referenced = ModelFamily.entries.any { activeName(it) == candidate.name } ||
            pendingActivationName() == candidate.name
        if (referenced) false else candidate.deleteRecursively()
    }

    private fun recoverActivationUnlocked(): Boolean {
        val fields = runCatching { activationJournal.readLines() }.getOrNull() ?: return false
        if (fields.size != 3) { activationJournal.delete(); return false }
        val family = runCatching { ModelFamily.valueOf(fields[0]) }.getOrNull()
        val name = fields[1]
        val id = fields[2]
        if (family == null || !SAFE_NAME.matches(name) || !File(directory, name).exists()) {
            activationJournal.delete()
            return false
        }
        replacePointerUnlocked(family, name, id)
        selectFamilyUnlocked(family)
        activationJournal.delete()
        return true
    }

    private fun pendingActivationName(): String? = runCatching {
        activationJournal.readLines().takeIf { it.size == 3 }?.get(1)
    }.getOrNull()?.takeIf(SAFE_NAME::matches)

    private fun selectFamilyUnlocked(family: ModelFamily) =
        atomicWrite(selectedPointer, family.name, "selected-${UUID.randomUUID()}")

    private fun pointerFor(family: ModelFamily) = File(directory, "active-${family.name.lowercase()}")

    private fun atomicWrite(target: File, value: String, temporaryName: String) {
        target.parentFile?.mkdirs()
        val temporary = File(target.parentFile, ".$temporaryName-${UUID.randomUUID()}")
        try {
            FileOutputStream(temporary).use { output ->
                output.write(value.toByteArray(Charsets.UTF_8))
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

    companion object {
        private val SAFE_NAME = Regex("(parakeet|whisper)-[0-9a-fA-F-]+(\\.bin)?")
    }
}
