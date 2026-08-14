package app.nuvi.android.infrastructure.model

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import app.nuvi.android.domain.ModelBundle
import app.nuvi.android.domain.ModelFamily
import app.nuvi.android.domain.ModelSnapshot
import app.nuvi.android.infrastructure.asr.RuntimeLeaseFile
import app.nuvi.android.infrastructure.parakeet.ParakeetBundleValidator
import app.nuvi.android.infrastructure.parakeet.ParakeetOfflineEngine
import app.nuvi.android.infrastructure.whisper.WhisperNativeEngine
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID

/**
 * Owns model files and their tiny active pointers.
 *
 * Lock contract:
 * - [bundleFor], [activeBundle], and [hasModel] never wait for an import.
 * - the import job lock serializes heavyweight copy/extract/probe work across processes.
 * - the activation lock protects only the final pointer swap.
 */
class ModelStore(private val context: Context) {
    data class ImportSource(
        val family: ModelFamily,
        val displayName: String,
        val opaqueId: String,
        val sizeBytes: Long?
    )

    data class ImportCallbacks(
        val onStage: (ImportStage, Int) -> Unit = { _, _ -> },
        val isCancelled: () -> Boolean = { false },
        val beforeNativeProbe: () -> Unit = {},
        val candidateId: String = UUID.randomUUID().toString()
    )

    private val directory = File(context.filesDir, "models")
    private val statusIndex = ModelStatusIndex(directory)
    private val importJobs = ImportJobGuard(File(directory, "import.lock"))

    init { statusIndex.recoverActivation() }

    val selectedFamily: ModelFamily
        get() = statusIndex.selectedFamily
    val activeBundle: ModelBundle? get() = statusIndex.activeBundle
    val hasModel: Boolean get() = statusIndex.hasModel
    fun selectFamily(family: ModelFamily) {
        statusIndex.selectFamily(family)
    }

    /** Fast pointer read only. Full validation already happened before pointer activation. */
    fun bundleFor(family: ModelFamily): ModelBundle? {
        return statusIndex.bundleFor(family)
    }

    fun leaseSnapshot(): ModelSnapshotLease {
        val processLease = RuntimeLeaseFile(directory)
        val pid = android.os.Process.myPid()
        return statusIndex.withSnapshotLease { value ->
            val localLease = leases.acquire(value.bundle.root)
            try {
                processLease.write(pid, value.version, value.bundle.root)
            } catch (error: Throwable) {
                localLease.close()
                throw error
            }
            ModelSnapshotLease(value, localLease) {
                statusIndex.withStateLock { processLease.clear(pid) }
            }
        } ?: throw IOException("No validated ${selectedFamily.displayName} model is active")
    }

    fun publishRuntimeLease(pid: Int, version: String, root: File) = statusIndex.withStateLock {
        RuntimeLeaseFile(directory).write(pid, version, root)
    }

    fun clearRuntimeLease(pid: Int) = statusIndex.withStateLock {
        RuntimeLeaseFile(directory).clear(pid)
    }

    fun isCandidateActive(family: ModelFamily, candidateId: String): Boolean =
        statusIndex.activeName(family)?.contains(candidateId) == true

    fun recoverActivation(): Boolean = statusIndex.recoverActivation()

    fun inspectSource(uri: Uri, resolver: ContentResolver = context.contentResolver): ImportSource {
        val displayName = queryDisplayName(uri, resolver)
        val family = if (displayName.endsWith(".tar.bz2", ignoreCase = true) || isBzip2(uri, resolver)) {
            ModelFamily.PARAKEET
        } else {
            ModelFamily.WHISPER
        }
        return ImportSource(
            family = family,
            displayName = displayName.take(120),
            opaqueId = sha256(uri.toString()),
            sizeBytes = querySize(uri, resolver)
        )
    }

    @Throws(IOException::class)
    fun importModel(
        uri: Uri,
        source: ImportSource = inspectSource(uri),
        resolver: ContentResolver = context.contentResolver,
        callbacks: ImportCallbacks = ImportCallbacks()
    ): ModelBundle = withImportJob {
        checkCancelled(callbacks)
        when (source.family) {
            ModelFamily.PARAKEET -> importParakeetArchive(uri, resolver, callbacks)
            ModelFamily.WHISPER -> importWhisper(uri, source.displayName, resolver, callbacks)
        }
    }

    fun cleanupTerminalImport(candidateId: String): Int =
        TerminalImportCleaner(directory, importJobs).clean(candidateId)

    fun isImportJobRunningAcrossProcesses(): Boolean = importJobs.isLocked()

    private fun importParakeetArchive(
        uri: Uri,
        resolver: ContentResolver,
        callbacks: ImportCallbacks
    ): ModelBundle.Parakeet {
        directory.mkdirs()
        val id = callbacks.candidateId
        val staging = File(directory, ".import-$id")
        val candidate = File(directory, "parakeet-$id")
        staging.mkdirs()
        try {
            callbacks.onStage(ImportStage.EXTRACTING, 1)
            resolver.openInputStream(uri)?.use { raw ->
                ParakeetArchiveExtractor.extract(
                    raw,
                    staging,
                    onProgress = { callbacks.onStage(ImportStage.EXTRACTING, it.coerceIn(1, 85)) },
                    isCancelled = callbacks.isCancelled
                )
            } ?: throw IOException("MODEL_INVALID: selected archive could not be opened")
            checkCancelled(callbacks)
            callbacks.onStage(ImportStage.STRUCTURAL_VALIDATION, 88)
            val stagedBundle = ModelBundle.Parakeet(staging)
            ParakeetBundleValidator.validate(stagedBundle)
            checkCancelled(callbacks)
            callbacks.onStage(ImportStage.NATIVE_PROBE, 92)
            callbacks.beforeNativeProbe()
            try {
                ParakeetOfflineEngine(stagedBundle).close()
            } catch (error: Throwable) {
                throw IOException("MODEL_VALIDATION_FAILED: sherpa-onnx could not load this Parakeet bundle", error)
            }
            checkCancelled(callbacks)
            callbacks.onStage(ImportStage.ACTIVATING, 98)
            publishAndActivate(ModelFamily.PARAKEET, staging, candidate, id)
            return ModelBundle.Parakeet(candidate)
        } finally {
            staging.deleteRecursively()
            if (candidate.exists()) statusIndex.deleteCandidateIfUnpublished(candidate)
        }
    }

    private fun importWhisper(
        uri: Uri,
        displayName: String,
        resolver: ContentResolver,
        callbacks: ImportCallbacks
    ): ModelBundle.Whisper {
        directory.mkdirs()
        val id = callbacks.candidateId
        val temporary = File(directory, ".import-$id.bin")
        val candidate = File(directory, "whisper-$id.bin")
        try {
            callbacks.onStage(ImportStage.COPYING, 1)
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(temporary).use { output ->
                    val buffer = ByteArray(128 * 1024)
                    var written = 0L
                    while (true) {
                        checkCancelled(callbacks)
                        val read = input.read(buffer)
                        if (read < 0) break
                        written += read
                        if (written > MAX_WHISPER_BYTES) throw IOException("MODEL_INVALID: Whisper model exceeds 2 GB")
                        output.write(buffer, 0, read)
                        callbacks.onStage(
                            ImportStage.COPYING,
                            (written / (25L * 1024L * 1024L)).toInt().coerceIn(1, 85)
                        )
                    }
                    output.fd.sync()
                }
            } ?: throw IOException("MODEL_INVALID: selected model could not be opened")
            callbacks.onStage(ImportStage.STRUCTURAL_VALIDATION, 88)
            GgmlModelFileValidator.validate(temporary, displayName)
            checkCancelled(callbacks)
            callbacks.onStage(ImportStage.NATIVE_PROBE, 92)
            callbacks.beforeNativeProbe()
            try {
                WhisperNativeEngine(temporary).close()
            } catch (error: Throwable) {
                throw IOException("MODEL_VALIDATION_FAILED: whisper.cpp could not load this model", error)
            }
            checkCancelled(callbacks)
            callbacks.onStage(ImportStage.ACTIVATING, 98)
            publishAndActivate(ModelFamily.WHISPER, temporary, candidate, id)
            return ModelBundle.Whisper(candidate)
        } finally {
            temporary.delete()
            if (candidate.exists()) statusIndex.deleteCandidateIfUnpublished(candidate)
        }
    }

    private fun publishAndActivate(family: ModelFamily, staging: File, candidate: File, id: String) {
        statusIndex.publishAndActivateTransactional(
            family = family,
            name = candidate.name,
            id = id,
            publish = { Files.move(staging.toPath(), candidate.toPath(), StandardCopyOption.ATOMIC_MOVE) }
        ) { previous ->
            previous?.takeIf { it != candidate }?.let(::markRetired)
        }
    }

    private fun markRetired(file: File) {
        // Cross-process inference leases cannot safely delete a live mmap. Mark it and clean it on a future cold start.
        runCatching { File(directory, ".retired-${file.name}").writeText(file.name) }
    }

    fun cleanupRetiredAndUnreferenced(): Int {
        return statusIndex.withStateLock {
            val active = ModelFamily.entries.mapNotNull(statusIndex::activeName).toSet()
            val runtimeLeases = RuntimeLeaseFile(directory).leasedRootNames()
            RetiredBundleCleaner.clean(directory, active, runtimeLeases)
        }
    }

    private fun replacePointer(family: ModelFamily, name: String, id: String) =
        statusIndex.replacePointer(family, name, id)

    private fun activeName(family: ModelFamily): String? = statusIndex.activeName(family)

    private fun queryDisplayName(uri: Uri, resolver: ContentResolver): String {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                .takeIf { it >= 0 }?.let(cursor::getString)?.let { return it }
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "model"
    }

    private fun querySize(uri: Uri, resolver: ContentResolver): Long? {
        resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 }?.let { index ->
                if (!cursor.isNull(index)) return cursor.getLong(index).takeIf { it >= 0L }
            }
        }
        return null
    }

    private fun isBzip2(uri: Uri, resolver: ContentResolver): Boolean = runCatching {
        resolver.openInputStream(uri)?.use { input ->
            input.read() == 'B'.code && input.read() == 'Z'.code && input.read() == 'h'.code
        } == true
    }.getOrDefault(false)

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    private fun checkCancelled(callbacks: ImportCallbacks) {
        if (callbacks.isCancelled()) throw ImportCancelledException()
    }

    private fun <T> withImportJob(block: () -> T): T {
        return importJobs.runExclusive(block)
    }

    class ModelSnapshotLease(
        val snapshot: ModelSnapshot,
        private val lease: ModelLeaseRegistry.Lease,
        private val onClose: () -> Unit
    ) : AutoCloseable {
        private val closed = java.util.concurrent.atomic.AtomicBoolean(false)
        override fun close() {
            if (closed.compareAndSet(false, true)) {
                lease.close()
                onClose()
            }
        }
    }

    companion object {
        private const val MAX_WHISPER_BYTES = 2_000L * 1024L * 1024L
        private val leases = ModelLeaseRegistry { it.deleteRecursively() }
    }
}
