package app.nuvi.android.application

import android.content.Context
import android.os.SystemClock
import android.util.Log
import app.nuvi.android.domain.ModelFamily
import app.nuvi.android.domain.SessionGeneration
import app.nuvi.android.domain.TranscriptNormalizer
import app.nuvi.android.domain.TranscriptionErrorCode
import app.nuvi.android.domain.TranscriptionFailure
import app.nuvi.android.domain.TranscriptionTiming
import app.nuvi.android.infrastructure.audio.AudioCaptureFactory
import app.nuvi.android.infrastructure.audio.BoundedPcm16Buffer
import app.nuvi.android.infrastructure.audio.PcmAudioRecorder
import app.nuvi.android.infrastructure.model.ModelStore
import app.nuvi.android.infrastructure.asr.AsrRuntimeClient
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeoutException

class DictationSessionController(
    private val context: Context,
    private val modelStore: ModelStore = ModelStore(context),
    private val captureFactory: AudioCaptureFactory = PcmAudioRecorder(context),
    private val scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
) : AutoCloseable {
    sealed interface State {
        data object Idle : State
        data object Recording : State
        data class FinishingCapture(val elapsedMillis: Long = 0) : State
        data class LoadingModel(val family: ModelFamily, val elapsedMillis: Long = 0) : State
        data class Transcribing(val family: ModelFamily, val elapsedMillis: Long = 0) : State
        data object Success : State
        data class Error(val code: TranscriptionErrorCode, val message: String) : State
    }

    private val generation = SessionGeneration()
    private val captureOwnership = CaptureOwnership()
    private val requestOwnership = RequestOwnership()
    private val asrClient = AsrRuntimeClient(context)
    @Volatile private var state: State = State.Idle
    @Volatile private var closed = false

    fun state(): State = state

    fun invalidate() {
        generation.next()
        requestOwnership.cancelActive()
        asrClient.abortActive()
        captureOwnership.cancel()
        state = State.Idle
    }

    @Synchronized
    fun start(
        onState: (State) -> Unit,
        onLimitReached: (Long) -> Unit,
        onLevel: (Float) -> Unit = {}
    ): Long {
        check(!closed) { "Dictation controller is closed" }
        check(modelStore.hasModel) { "MODEL_MISSING: Import a ${modelStore.selectedFamily.displayName} model first" }
        val token = generation.next()
        val request = RequestContext.create(token, SystemClock.elapsedRealtime(), MAX_REQUEST_LIFETIME_MILLIS)
        requestOwnership.replace(request)
        val handle = captureFactory.create(
            onFailure = { error ->
                if (generation.isCurrent(token)) {
                    captureOwnership.cancel(token)
                    fail(TranscriptionErrorCode.ENGINE_FAILED, error.message ?: "Microphone capture failed", onState)
                }
            },
            onLimitReached = { if (generation.isCurrent(token)) onLimitReached(token) },
            onLevel = { level -> if (generation.isCurrent(token)) onLevel(level) }
        )
        captureOwnership.attach(token, handle)
        try { handle.start() } catch (error: Throwable) {
            captureOwnership.cancel()
            throw error
        }
        setState(State.Recording, onState)
        return token
    }

    fun stopAndTranscribe(token: Long, onState: (State) -> Unit, onResult: (Long, String) -> Unit) {
        if (closed || !generation.isCurrent(token)) return
        val request = requestOwnership.current()?.takeIf { it.generation == token } ?: return
        val started = SystemClock.elapsedRealtime()
        val captured = captureOwnership.stop(token) ?: return
        setState(State.FinishingCapture(), onState)
        val captureTimeout = RequestDeadline.arm(
            captured, scheduler, TranscriptionTiming.CAPTURE_SETTLE_MILLIS,
            TranscriptionErrorCode.CAPTURE_TIMEOUT, "Microphone did not finish within 3 seconds"
        )

        captured.whenComplete { pcm16, captureError ->
            captureTimeout.cancel(false)
            if (!generation.isCurrent(token)) return@whenComplete
            if (captureError != null) {
                val code = if (unwrap(captureError) is TimeoutException || unwrap(captureError) is TranscriptionFailure) {
                    TranscriptionErrorCode.CAPTURE_TIMEOUT
                } else TranscriptionErrorCode.ENGINE_FAILED
                fail(code, unwrap(captureError).message ?: "Capture failed", onState)
                return@whenComplete
            }
            val pcm = BoundedPcm16Buffer.toFloat(pcm16)
            if (pcm.isEmpty()) {
                fail(TranscriptionErrorCode.NO_SPEECH, "No speech detected", onState)
                return@whenComplete
            }
            transcribe(request, pcm, started, onState, onResult)
        }
    }

    private fun transcribe(request: RequestContext, pcm: FloatArray, started: Long, onState: (State) -> Unit, onResult: (Long, String) -> Unit) {
        val token = request.generation
        val snapshotLease = try { modelStore.leaseSnapshot() } catch (error: Throwable) {
            fail(TranscriptionErrorCode.MODEL_MISSING, error.message ?: "No active model", onState)
            return
        }
        val snapshot = snapshotLease.snapshot
        val family = snapshot.family
        requestOwnership.ifOwned(request) { setState(State.LoadingModel(family, SystemClock.elapsedRealtime() - started), onState) }
        val remainingLifetime = (request.deadlineAtMillis - SystemClock.elapsedRealtime()).coerceAtLeast(1L)
        val call = try { asrClient.begin(request.id, snapshot, pcm) } catch (error: Throwable) {
            snapshotLease.close()
            fail((error as? TranscriptionFailure)?.code ?: TranscriptionErrorCode.IPC_FAILED,
                error.message ?: "Unable to start isolated ASR", onState)
            return
        }
        val inferenceWatchdog = AtomicReference<java.util.concurrent.ScheduledFuture<*>?>()
        val loadDeadline = minOf(MODEL_LOAD_TIMEOUT_MILLIS, remainingLifetime)
        val loadWatchdog = RequestDeadline.arm(
            call.ready, scheduler, loadDeadline, TranscriptionErrorCode.MODEL_LOAD_TIMEOUT,
            "Local model loading exceeded ${loadDeadline / 1000}s"
        ) { asrClient.abort(request.id, TranscriptionErrorCode.MODEL_LOAD_TIMEOUT, "Local model loading timed out") }
        call.ready.whenComplete { _, readyError ->
            loadWatchdog.cancel(false)
            if (readyError == null && requestOwnership.owns(request)) {
                setState(State.Transcribing(family, SystemClock.elapsedRealtime() - started), onState)
                val inferenceDeadline = minOf(TranscriptionTiming.inferenceDeadlineMillis(pcm.size),
                    (request.deadlineAtMillis - SystemClock.elapsedRealtime()).coerceAtLeast(1L))
                inferenceWatchdog.set(RequestDeadline.arm(
                    call.result, scheduler, inferenceDeadline, TranscriptionErrorCode.ENGINE_TIMEOUT,
                    "Local transcription exceeded ${inferenceDeadline / 1000}s"
                ) { asrClient.abort(request.id, TranscriptionErrorCode.ENGINE_TIMEOUT, "Local transcription timed out") })
            }
        }
        call.result.whenComplete { rawText, error ->
            loadWatchdog.cancel(false)
            inferenceWatchdog.getAndSet(null)?.cancel(false)
            snapshotLease.close()
            requestOwnership.ifActive(request) {
                val elapsed = SystemClock.elapsedRealtime() - started
                if (error != null) {
                    val root = unwrap(error)
                    val failure = root as? TranscriptionFailure
                    val code = failure?.code ?: if (request.isCancelled) TranscriptionErrorCode.CANCELLED else TranscriptionErrorCode.ENGINE_FAILED
                    diagnostic(family, token, pcm.size, "error", elapsed, code)
                    if (code != TranscriptionErrorCode.CANCELLED) fail(code, root.message ?: "Local transcription failed", onState)
                } else {
                    val text = TranscriptNormalizer.normalize(rawText)
                    if (!requestOwnership.owns(request)) {
                        requestOwnership.cancel(request)
                        return@ifActive
                    }
                    if (text.isBlank()) {
                        fail(TranscriptionErrorCode.NO_SPEECH, "No speech detected", onState)
                    } else {
                        diagnostic(family, token, pcm.size, "complete", elapsed, null)
                        setState(State.Success, onState)
                        onResult(token, text)
                    }
                }
                requestOwnership.cancel(request)
            }
        }
    }

    fun cancel(onState: (State) -> Unit = {}) {
        invalidate()
        setState(State.Idle, onState)
    }

    fun isCurrent(token: Long): Boolean = generation.isCurrent(token)

    private fun fail(code: TranscriptionErrorCode, message: String, callback: (State) -> Unit) = setState(State.Error(code, message), callback)
    private fun setState(value: State, callback: (State) -> Unit) { state = value; callback(value) }
    private fun unwrap(error: Throwable): Throwable = error.cause?.takeIf { error is java.util.concurrent.CompletionException } ?: error

    private fun diagnostic(family: ModelFamily, token: Long, samples: Int, phase: String, elapsed: Long, code: TranscriptionErrorCode?) {
        val memoryMb = (Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory()) / 1_048_576L
        Log.i(TAG, "engine=${family.name} request=$token samples=$samples durationMs=${samples * 1000L / 16000} phase=$phase elapsedMs=$elapsed code=${code?.name ?: "OK"} memoryMb=$memoryMb")
    }

    override fun close() {
        if (closed) return
        closed = true
        invalidate()
        scheduler.shutdownNow()
        asrClient.close()
    }

    companion object {
        private const val TAG = "NuviAsr"
        private const val MAX_REQUEST_LIFETIME_MILLIS = 400_000L
        private const val MODEL_LOAD_TIMEOUT_MILLIS = 5L * 60L * 1_000L
    }
}
