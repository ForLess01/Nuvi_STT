package app.nuvi.android.application

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Handler
import android.os.Looper
import app.nuvi.android.domain.ModelFamily
import app.nuvi.android.infrastructure.model.ImportJournal
import app.nuvi.android.infrastructure.model.ImportJournalStore
import app.nuvi.android.infrastructure.model.ImportStage
import app.nuvi.android.infrastructure.model.ImportWatchdogPolicy
import app.nuvi.android.infrastructure.model.ModelImportService
import app.nuvi.android.infrastructure.model.ModelStore
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class ModelImportCoordinator private constructor(context: Context) {
    sealed interface State {
        data object Idle : State
        data class Running(val family: ModelFamily, val stage: ImportStage, val progress: Int, val elapsedMillis: Long) : State
        data class Success(val family: ModelFamily, val sizeMb: Long) : State
        data class Error(val code: String, val stage: ImportStage) : State
    }

    private val applicationContext = context.applicationContext
    private val journalStore = ImportJournalStore(File(applicationContext.filesDir, "models"))
    private val mainHandler = Handler(Looper.getMainLooper())
    private val modelStore = ModelStore(applicationContext)

    init {
        val now = System.currentTimeMillis()
        val current = journalStore.read()
        val completedAfterActivation = current?.takeIf {
            it.isActive && modelStore.isCandidateActive(it.family, it.candidateId)
        }?.let {
            journalStore.write(it.copy(
                stage = ImportStage.COMPLETE,
                percent = 100,
                updatedAtMs = now,
                sizeMb = modelStore.bundleFor(it.family)?.root?.let(::bundleSizeMb)
            ))
        }
        val recovered = completedAfterActivation ?: when {
            current == null || !current.isActive -> current
            current.stage == ImportStage.PREFLIGHT -> {
                val code = ImportWatchdogPolicy.timeoutCode(current, now)
                if (code == null) current else journalStore.write(
                    current.copy(stage = ImportStage.FAILED, updatedAtMs = now, errorCode = code)
                ).also { requestSelfTermination(current.candidateId) }
            }
            current.stage == ImportStage.NATIVE_PROBE && modelStore.isImportJobRunningAcrossProcesses() -> {
                val code = ImportWatchdogPolicy.timeoutCode(current, now)
                if (code == null) current else journalStore.write(
                    current.copy(stage = ImportStage.FAILED, updatedAtMs = now, errorCode = code)
                ).also { requestSelfTermination(current.candidateId) }
            }
            now - current.updatedAtMs < ABANDONED_GRACE_MS -> current
            else -> journalStore.recoverInterrupted(
                nowMs = now,
                activeProcessOwnsJob = modelStore.isImportJobRunningAcrossProcesses()
            )
        }
        if (recovered?.stage?.terminal == true) {
            modelStore.cleanupTerminalImport(recovered.candidateId)
            modelStore.cleanupRetiredAndUnreferenced()
        }
    }

    fun isRunning(): Boolean = journalStore.read()?.isActive == true
    fun state(): State {
        val journal = journalStore.read()
        if (journal?.stage?.terminal == true) modelStore.cleanupTerminalImport(journal.candidateId)
        return stateFrom(journal)
    }

    fun observe(observer: (State) -> Unit): AutoCloseable {
        val active = AtomicBoolean(true)
        val dispatcher = LatestValueDispatcher<State>(
            schedule = { mainHandler.post(it) },
            consumer = { if (active.get()) observer(it) }
        )
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                dispatcher.offer(state())
            }
        }
        val filter = IntentFilter(ModelImportService.ACTION_STATE_CHANGED)
        applicationContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        dispatcher.offer(state())
        val livenessPoll = object : Runnable {
            override fun run() {
                if (!active.get()) return
                recoverAbandonedImport()?.let(dispatcher::offer)
                mainHandler.postDelayed(this, LIVENESS_POLL_MS)
            }
        }
        mainHandler.postDelayed(livenessPoll, LIVENESS_POLL_MS)
        return AutoCloseable {
            if (active.compareAndSet(true, false)) {
                mainHandler.removeCallbacks(livenessPoll)
                runCatching { applicationContext.unregisterReceiver(receiver) }
            }
        }
    }

    fun start(uri: Uri): Boolean {
        if (isRunning()) return false
        val intent = Intent(applicationContext, ModelImportService::class.java)
            .setAction(ModelImportService.ACTION_START)
            .setData(uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .putExtra(ModelImportService.EXTRA_URI, uri.toString())
        applicationContext.startForegroundService(intent)
        return true
    }

    fun cancel() {
        applicationContext.startService(
            Intent(applicationContext, ModelImportService::class.java).setAction(ModelImportService.ACTION_CANCEL)
        )
    }

    private fun stateFrom(journal: ImportJournal?): State = when {
        journal == null -> State.Idle
        journal.isActive -> State.Running(
            journal.family,
            journal.stage,
            journal.percent,
            (System.currentTimeMillis() - journal.stageStartedAtMs).coerceAtLeast(0L)
        )
        journal.stage == ImportStage.COMPLETE -> State.Success(journal.family, journal.sizeMb ?: 0L)
        else -> State.Error(journal.errorCode ?: "MODEL_INVALID", journal.stage)
    }

    private fun recoverAbandonedImport(): State? {
        val journal = journalStore.read() ?: return null
        if (!journal.isActive) return null
        val now = System.currentTimeMillis()
        if (journal.stage == ImportStage.PREFLIGHT) {
            val code = ImportWatchdogPolicy.timeoutCode(journal, now) ?: return null
            val terminal = journal.copy(stage = ImportStage.FAILED, updatedAtMs = now, errorCode = code)
            val persisted = journalStore.write(terminal)
            requestSelfTermination(journal.candidateId)
            modelStore.cleanupTerminalImport(persisted.candidateId)
            return stateFrom(persisted)
        }
        if (journal.stage == ImportStage.NATIVE_PROBE) {
            if (!modelStore.isImportJobRunningAcrossProcesses()) {
                val recovered = journalStore.recoverInterrupted(now, activeProcessOwnsJob = false)
                recovered?.let { modelStore.cleanupTerminalImport(it.candidateId) }
                return stateFrom(recovered)
            }
            if (ImportWatchdogPolicy.timeoutCode(journal, now) != "MODEL_LOAD_TIMEOUT") return null
            val terminal = journal.copy(
                stage = ImportStage.FAILED,
                updatedAtMs = now,
                errorCode = "MODEL_LOAD_TIMEOUT"
            )
            val persisted = journalStore.write(terminal)
            requestSelfTermination(journal.candidateId)
            modelStore.cleanupTerminalImport(persisted.candidateId)
            return stateFrom(persisted)
        }
        if (now - journal.updatedAtMs < ABANDONED_GRACE_MS) return null
        if (modelStore.isImportJobRunningAcrossProcesses()) return null
        val recovered = journalStore.recoverInterrupted(now, activeProcessOwnsJob = false)
        recovered?.let { modelStore.cleanupTerminalImport(it.candidateId) }
        return stateFrom(recovered)
    }

    private fun requestSelfTermination(candidateId: String) {
        runCatching {
            applicationContext.startService(
                Intent(applicationContext, ModelImportService::class.java)
                    .setAction(ModelImportService.ACTION_TERMINATE)
                    .putExtra(ModelImportService.EXTRA_CANDIDATE_ID, candidateId)
            )
        }
    }

    private fun bundleSizeMb(root: File): Long = if (root.isDirectory) {
        root.walkTopDown().filter(File::isFile).sumOf(File::length) / 1_048_576L
    } else root.length() / 1_048_576L

    companion object {
        private const val LIVENESS_POLL_MS = 1_000L
        private const val ABANDONED_GRACE_MS = 3_000L
        @Volatile private var instance: ModelImportCoordinator? = null
        fun get(context: Context): ModelImportCoordinator = instance ?: synchronized(this) {
            instance ?: ModelImportCoordinator(context.applicationContext).also { instance = it }
        }
    }
}
