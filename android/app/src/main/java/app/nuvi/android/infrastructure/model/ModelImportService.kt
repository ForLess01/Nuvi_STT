package app.nuvi.android.infrastructure.model

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.IBinder
import android.os.Process
import android.os.StatFs
import app.nuvi.android.R
import app.nuvi.android.application.ImportProgressThrottle
import app.nuvi.android.domain.ModelBundle
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class ModelImportService : Service() {
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "nuvi-isolated-model-import").apply { isDaemon = true }
    }
    private val running = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    private val watchdog = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "nuvi-import-watchdog").apply { isDaemon = true }
    }
    private val activeJournal = AtomicReference<ImportJournal?>(null)
    private val journalWriteLock = Any()
    private val timeoutCode = AtomicReference<String?>(null)
    private var watchdogTask: ScheduledFuture<*>? = null
    private lateinit var modelStore: ModelStore
    private lateinit var journalStore: ImportJournalStore

    override fun onCreate() {
        super.onCreate()
        modelStore = ModelStore(this)
        journalStore = ImportJournalStore(File(filesDir, "models"))
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TERMINATE -> terminateIfOwned(intent.getStringExtra(EXTRA_CANDIDATE_ID))
            ACTION_CANCEL -> {
                cancelled.set(true)
                if (running.get()) {
                    val current = activeJournal.get()
                    if (current?.stage == ImportStage.NATIVE_PROBE) {
                        writeJournal(current.copy(
                            stage = ImportStage.CANCELLED,
                            updatedAtMs = System.currentTimeMillis(),
                            errorCode = "IMPORT_CANCELLED"
                        ), force = true)
                        terminateIfOwned(current.candidateId)
                    } else {
                        startForeground(NOTIFICATION_ID, notification(getString(R.string.model_import_cancelling), 0, false))
                    }
                } else {
                    stopSelf()
                }
            }
            ACTION_START -> startImport(intent)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        cancelled.set(true)
        executor.shutdownNow()
        watchdog.shutdownNow()
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        terminateForSystemTimeout("FGS_TIMEOUT")
    }

    override fun onTimeout(startId: Int) {
        terminateForSystemTimeout("FGS_TIMEOUT")
    }

    private fun terminateForSystemTimeout(code: String) {
        val current = activeJournal.get() ?: fallbackJournal("system-timeout")
        val now = System.currentTimeMillis()
        writeJournal(current.copy(stage = ImportStage.FAILED, updatedAtMs = now, errorCode = code), force = true)
        cancelled.set(true)
        terminateIfOwned(current.candidateId)
    }

    private fun terminateIfOwned(requestedCandidateId: String?) {
        val activeCandidateId = activeJournal.get()?.candidateId
        if (!ImportTerminationGate.shouldSelfTerminate(running.get(), activeCandidateId, requestedCandidateId)) {
            if (!running.get()) stopSelf()
            return
        }
        cancelled.set(true)
        Process.killProcess(Process.myPid())
    }

    private fun startImport(intent: Intent) {
        startForeground(NOTIFICATION_ID, notification(getString(R.string.model_import_preparing), 0, true))
        if (!running.compareAndSet(false, true)) {
            publishCurrent()
            return
        }
        val uri = intent.data ?: intent.getStringExtra(EXTRA_URI)?.let(Uri::parse)
        if (uri == null) {
            finishWithError("MODEL_INVALID", getString(R.string.model_import_source_missing))
            return
        }
        cancelled.set(false)
        timeoutCode.set(null)
        executor.execute {
            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
            runImport(uri)
        }
    }

    private fun runImport(uri: Uri) {
        var journal: ImportJournal? = null
        try {
            val preflightStarted = System.currentTimeMillis()
            journal = ImportPreflightSession.begin(
                provisionalFamily = modelStore.selectedFamily,
                nowMs = preflightStarted,
                workerPid = Process.myPid()
            )
            writeJournal(journal, force = true)
            startWatchdog()

            modelStore.cleanupRetiredAndUnreferenced()
            val source = modelStore.inspectSource(uri)
            journal = ImportPreflightSession.identify(journal, source, System.currentTimeMillis())
            writeJournal(journal, force = true)
            validateResources(source)

            val throttle = ImportProgressThrottle(System::currentTimeMillis)
            val bundle = modelStore.importModel(
                uri = uri,
                source = source,
                callbacks = ModelStore.ImportCallbacks(
                    onStage = { stage, percent ->
                        if (throttle.shouldEmit(stage, percent)) {
                            journal = journal!!.advance(stage, percent, System.currentTimeMillis())
                            writeJournal(journal!!)
                        }
                    },
                    isCancelled = { cancelled.get() || Thread.currentThread().isInterrupted },
                    beforeNativeProbe = { validateMemoryOnly(source.family) },
                    candidateId = journal!!.candidateId
                )
            )
            val complete = journal!!.copy(
                stage = ImportStage.COMPLETE,
                percent = 100,
                updatedAtMs = System.currentTimeMillis(),
                sizeMb = bundleSizeMb(bundle)
            )
            writeJournal(complete, force = true)
        } catch (cancel: ImportCancelledException) {
            val base = journal ?: fallbackJournal("cancelled")
            val terminal = base.copy(
                stage = ImportStage.CANCELLED,
                updatedAtMs = System.currentTimeMillis(),
                errorCode = "IMPORT_CANCELLED"
            )
            writeJournal(terminal, force = true)
        } catch (error: Throwable) {
            val message = error.message ?: "MODEL_INVALID: Import failed"
            val code = timeoutCode.get() ?:
                (message.substringBefore(':').takeIf { it.matches(Regex("[A-Z_]+")) } ?: "MODEL_INVALID")
            val base = journal ?: fallbackJournal("failed")
            modelStore.recoverActivation()
            val activated = modelStore.isCandidateActive(base.family, base.candidateId)
            val terminal = if (activated) base.copy(
                stage = ImportStage.COMPLETE,
                percent = 100,
                updatedAtMs = System.currentTimeMillis(),
                errorCode = null,
                sizeMb = modelStore.bundleFor(base.family)?.let(::bundleSizeMb)
            ) else base.copy(
                stage = ImportStage.FAILED,
                updatedAtMs = System.currentTimeMillis(),
                errorCode = code
            )
            writeJournal(terminal, force = true, detail = message.substringAfter(':', message).trim())
        } finally {
            watchdogTask?.cancel(false)
            journal?.candidateId?.let(modelStore::cleanupTerminalImport)
            modelStore.cleanupRetiredAndUnreferenced()
            running.set(false)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun startWatchdog() {
        watchdogTask?.cancel(false)
        watchdogTask = watchdog.scheduleAtFixedRate({ watchdogTick() }, 1L, 1L, TimeUnit.SECONDS)
    }

    private fun watchdogTick() {
        val current = activeJournal.get() ?: return
        if (!current.isActive) return
        val now = System.currentTimeMillis()
        val timeout = ImportWatchdogPolicy.timeoutCode(current, now)
        if (timeout != null) {
            timeoutCode.compareAndSet(null, timeout)
            cancelled.set(true)
            val terminal = current.copy(
                stage = ImportStage.FAILED,
                updatedAtMs = now,
                errorCode = timeout
            )
            writeJournal(terminal, force = true)
            // The native constructor is not cancellable. This process exists specifically so a hard
            // timeout cannot poison the UI/IME process or its transcription permit.
            terminateIfOwned(current.candidateId)
            return
        }
    }

    private fun writeJournal(value: ImportJournal, force: Boolean = false, detail: String? = null) {
        synchronized(journalWriteLock) {
            val current = activeJournal.get()
            if (current?.candidateId == value.candidateId && current.stage.terminal && !value.stage.terminal) return
            val persisted = journalStore.write(value)
            activeJournal.set(persisted)
            if (persisted != value) return
        }
        publish(value, force, detail)
    }

    private fun validateResources(source: ModelStore.ImportSource) {
        val stat = StatFs(filesDir.absolutePath)
        val memory = memoryInfo()
        ImportPreflightPolicy.validate(
            source.family,
            ImportResources(stat.availableBytes, memory.availMem, memory.lowMemory, source.sizeBytes)
        )
    }

    private fun validateMemoryOnly(family: app.nuvi.android.domain.ModelFamily) {
        val memory = memoryInfo()
        ImportPreflightPolicy.validateMemory(family, memory.availMem, memory.lowMemory)
    }

    private fun memoryInfo() = ActivityManager.MemoryInfo().also {
        (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(it)
    }

    private fun publish(journal: ImportJournal, force: Boolean = false, detail: String? = null) {
        val label = stageLabel(journal.stage, detail)
        if (journal.isActive || force) {
            startForeground(NOTIFICATION_ID, notification(label, journal.percent, journal.isActive))
        }
        sendBroadcast(Intent(ACTION_STATE_CHANGED).apply {
            setPackage(packageName)
            putExtra(EXTRA_STAGE, journal.stage.name)
            putExtra(EXTRA_PERCENT, journal.percent)
        })
    }

    private fun publishCurrent() {
        journalStore.read()?.let { publish(it, force = true) }
    }

    private fun finishWithError(code: String, detail: String) {
        val journal = fallbackJournal("invalid").copy(
            stage = ImportStage.FAILED,
            errorCode = code,
            updatedAtMs = System.currentTimeMillis()
        )
        writeJournal(journal, force = true, detail = detail)
        running.set(false)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun fallbackJournal(source: String): ImportJournal {
        val now = System.currentTimeMillis()
        return ImportJournal(
            family = app.nuvi.android.domain.ModelFamily.PARAKEET,
            sourceLabel = source,
            sourceId = source,
            stage = ImportStage.PREFLIGHT,
            percent = 0,
            startedAtMs = now,
            updatedAtMs = now,
            candidateId = UUID.randomUUID().toString()
        )
    }

    private fun bundleSizeMb(bundle: ModelBundle): Long = when (bundle) {
        is ModelBundle.Parakeet -> listOf(bundle.encoder, bundle.decoder, bundle.joiner, bundle.tokens).sumOf(File::length)
        is ModelBundle.Whisper -> bundle.root.length()
    } / 1_048_576L

    private fun stageLabel(stage: ImportStage, detail: String?): String = detail ?: when (stage) {
        ImportStage.PREFLIGHT -> getString(R.string.model_import_preparing)
        ImportStage.EXTRACTING -> getString(R.string.model_import_extracting)
        ImportStage.COPYING -> getString(R.string.model_import_copying)
        ImportStage.STRUCTURAL_VALIDATION -> getString(R.string.model_import_validating)
        ImportStage.NATIVE_PROBE -> getString(R.string.model_import_testing)
        ImportStage.ACTIVATING -> getString(R.string.model_import_activating)
        ImportStage.COMPLETE -> getString(R.string.model_import_complete)
        ImportStage.CANCELLED -> getString(R.string.model_import_cancelled)
        ImportStage.INTERRUPTED -> getString(R.string.model_import_interrupted)
        ImportStage.FAILED -> getString(R.string.model_import_failed)
    }

    private fun notification(label: String, percent: Int, cancellable: Boolean): android.app.Notification {
        val cancelIntent = Intent(this, ModelImportService::class.java).setAction(ACTION_CANCEL)
        val cancel = PendingIntent.getService(this, 44, cancelIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return android.app.Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_nuvi_monochrome)
            .setContentTitle(getString(R.string.model_import_notification_title))
            .setContentText(label)
            .setOnlyAlertOnce(true)
            .setOngoing(cancellable)
            .setProgress(100, percent.coerceIn(0, 100), percent <= 0)
            .apply { if (cancellable) addAction(android.R.drawable.ic_menu_close_clear_cancel, getString(R.string.action_cancel), cancel) }
            .build()
    }

    private fun createNotificationChannel() {
        (getSystemService(NotificationManager::class.java)).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, getString(R.string.model_import_channel), NotificationManager.IMPORTANCE_LOW)
        )
    }

    companion object {
        const val ACTION_START = "app.nuvi.android.action.START_MODEL_IMPORT"
        const val ACTION_CANCEL = "app.nuvi.android.action.CANCEL_MODEL_IMPORT"
        const val ACTION_TERMINATE = "app.nuvi.android.action.TERMINATE_MODEL_IMPORT"
        const val ACTION_STATE_CHANGED = "app.nuvi.android.action.MODEL_IMPORT_STATE_CHANGED"
        const val EXTRA_URI = "model-uri"
        const val EXTRA_STAGE = "stage"
        const val EXTRA_PERCENT = "percent"
        const val EXTRA_CANDIDATE_ID = "candidate-id"
        private const val CHANNEL_ID = "nuvi-model-import"
        private const val NOTIFICATION_ID = 4202
    }
}
