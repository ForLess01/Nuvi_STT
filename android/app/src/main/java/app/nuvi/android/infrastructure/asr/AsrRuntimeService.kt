package app.nuvi.android.infrastructure.asr

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import app.nuvi.android.application.OfflineTranscriptionEngine
import app.nuvi.android.domain.ModelBundle
import app.nuvi.android.domain.ModelFamily
import app.nuvi.android.infrastructure.model.ModelStore
import app.nuvi.android.infrastructure.parakeet.ParakeetOfflineEngine
import app.nuvi.android.infrastructure.whisper.WhisperNativeEngine
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Killable native boundary. No native model construction or decode runs in the IME process. */
class AsrRuntimeService : Service() {
    private val handlerThread = HandlerThread("nuvi-asr-ipc")
    private val executor = Executors.newSingleThreadExecutor { task -> Thread(task, "nuvi-asr-native") }
    private lateinit var messenger: Messenger
    private lateinit var diagnostics: LocalAsrDiagnostics
    private lateinit var diagnosticReporter: BestEffortAsrDiagnostics
    private var cached: CachedEngine? = null
    private val executionGate = AsrExecutionGate()
    private var prepared: PreparedRequest? = null

    override fun onCreate() {
        super.onCreate()
        handlerThread.start()
        messenger = Messenger(Handler(handlerThread.looper, ::handleMessage))
        diagnostics = LocalAsrDiagnostics(File(filesDir, "models"))
        diagnosticReporter = BestEffortAsrDiagnostics(append = { diagnostics.append(it) })
    }

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        val nativeActive = executionGate.hasActiveRequest()
        prepared?.descriptor?.close()
        prepared = null
        if (nativeActive) {
            handlerThread.quit()
            super.onDestroy()
            Process.killProcess(Process.myPid())
            return
        }
        executor.shutdownNow()
        closeCached()
        handlerThread.quitSafely()
        super.onDestroy()
    }

    private fun handleMessage(message: Message): Boolean {
        when (message.what) {
            AsrProtocol.START -> prepare(message)
            AsrProtocol.EXECUTE -> executePrepared(message)
            AsrProtocol.CANCEL -> cancelPrepared(message.data.getString(AsrProtocol.REQUEST_ID))
        }
        return true
    }

    private fun prepare(message: Message) {
        val reply = message.replyTo ?: return
        val data = message.data
        val requestId = data.getString(AsrProtocol.REQUEST_ID) ?: return
        val family = runCatching { ModelFamily.valueOf(data.getString(AsrProtocol.FAMILY).orEmpty()) }.getOrNull()
        val root = data.getString(AsrProtocol.BUNDLE_ROOT)?.let(::File)
        val version = data.getString(AsrProtocol.BUNDLE_VERSION)
        val descriptor = if (android.os.Build.VERSION.SDK_INT >= 33) {
            data.getParcelable(AsrProtocol.AUDIO_FD, ParcelFileDescriptor::class.java)
        } else @Suppress("DEPRECATION") data.getParcelable(AsrProtocol.AUDIO_FD)
        val samples = data.getInt(AsrProtocol.SAMPLE_COUNT, -1)
        if (family == null || root == null || version.isNullOrBlank() || descriptor == null || samples < 0) {
            descriptor?.close()
            replyError(reply, requestId, "IPC_FAILED", "Invalid ASR request", null)
            return
        }
        if (!executionGate.prepare(requestId)) {
            descriptor.close()
            replyError(reply, requestId, "ENGINE_BUSY", "ASR process is already handling a request", null)
            return
        }
        prepared = PreparedRequest(reply, requestId, family, root, version, descriptor, samples)
        reply(reply, AsrProtocol.ACCEPTED, requestId) { putInt(AsrProtocol.PID, Process.myPid()) }
    }

    private fun executePrepared(message: Message) {
        val requestId = message.data.getString(AsrProtocol.REQUEST_ID) ?: return
        val request = prepared?.takeIf { it.requestId == requestId } ?: return
        if (!executionGate.authorize(requestId)) return
        prepared = null
        executor.execute {
            execute(
                request.reply,
                request.requestId,
                request.family,
                request.root,
                request.version,
                request.descriptor,
                request.sampleCount
            )
        }
    }

    private fun cancelPrepared(requestId: String?) {
        if (requestId == null) return
        val nativeActive = executionGate.ownsActive(requestId)
        if (!executionGate.cancel(requestId)) return
        prepared?.takeIf { it.requestId == requestId }?.descriptor?.close()
        if (prepared?.requestId == requestId) prepared = null
        // Only the dedicated process kills itself. The client never kills a potentially
        // recycled PID; the two-phase gate guarantees this handler owns the request.
        if (nativeActive) Process.killProcess(Process.myPid())
    }

    private fun execute(
        reply: Messenger,
        requestId: String,
        family: ModelFamily,
        root: File,
        version: String,
        descriptor: ParcelFileDescriptor,
        sampleCount: Int
    ) {
        var loadMillis = 0L
        var decodeMillis = 0L
        try {
            check(executionGate.ownsActive(requestId)) { "Request cancelled before native start" }
            val loadStarted = SystemClock.elapsedRealtime()
            val engine = engineFor(family, root, version)
            loadMillis = SystemClock.elapsedRealtime() - loadStarted
            reply(reply, AsrProtocol.READY, requestId) {
                putInt(AsrProtocol.PID, Process.myPid())
                putLong(AsrProtocol.LOAD_MILLIS, loadMillis)
            }
            check(executionGate.ownsActive(requestId)) { "Request cancelled before decode" }
            val pcm = descriptor.use { readPcm(it, sampleCount) }
            val decodeStarted = SystemClock.elapsedRealtime()
            val text = engine.transcribe(pcm, AtomicBoolean(false))
            decodeMillis = SystemClock.elapsedRealtime() - decodeStarted
            check(executionGate.ownsActive(requestId)) { "Request cancelled after decode" }
            diagnosticReporter.afterProtocol(
                protocolAction = {
                    reply(reply, AsrProtocol.RESULT, requestId) {
                        putString(AsrProtocol.TEXT, text)
                        putLong(AsrProtocol.LOAD_MILLIS, loadMillis)
                        putLong(AsrProtocol.DECODE_MILLIS, decodeMillis)
                    }
                },
                entry = { entry(requestId, "complete", family, version, "", loadMillis, decodeMillis) }
            )
        } catch (error: Throwable) {
            runCatching { descriptor.close() }
            diagnosticReporter.afterProtocol(
                protocolAction = {
                    replyError(reply, requestId, "ENGINE_FAILED", "Native ${family.displayName} operation failed", error)
                },
                entry = { entry(requestId, "error", family, version, error.javaClass.name, loadMillis, decodeMillis) }
            )
        } finally {
            executionGate.finish(requestId)
        }
    }

    private fun engineFor(family: ModelFamily, root: File, version: String): OfflineTranscriptionEngine {
        cached?.takeIf {
            EngineCachePolicy.canReuse(it.family, it.root, it.version, family, root, version)
        }?.let { return it.engine }
        closeCached()
        val modelStore = ModelStore(this)
        modelStore.publishRuntimeLease(Process.myPid(), version, root)
        val bundle = when (family) {
            ModelFamily.PARAKEET -> ModelBundle.Parakeet(root)
            ModelFamily.WHISPER -> ModelBundle.Whisper(root)
        }
        val engine = try {
            when (bundle) {
                is ModelBundle.Parakeet -> ParakeetOfflineEngine(bundle)
                is ModelBundle.Whisper -> WhisperNativeEngine(bundle.model)
            }
        } catch (error: Throwable) {
            modelStore.clearRuntimeLease(Process.myPid())
            throw error
        }
        cached = CachedEngine(family, root, version, engine)
        modelStore.cleanupRetiredAndUnreferenced()
        return engine
    }

    private fun closeCached() {
        cached?.let { runCatching { it.engine.close() } }
        cached = null
        ModelStore(this).clearRuntimeLease(Process.myPid())
    }

    private fun readPcm(descriptor: ParcelFileDescriptor, sampleCount: Int): FloatArray {
        val expectedBytes = sampleCount.toLong() * 4L
        require(expectedBytes in 0..MAX_PCM_BYTES) { "PCM payload is too large" }
        val bytes = ByteArray(expectedBytes.toInt())
        FileInputStream(descriptor.fileDescriptor).use { input ->
            var offset = 0
            while (offset < bytes.size) {
                val count = input.read(bytes, offset, bytes.size - offset)
                if (count < 0) error("PCM payload is truncated")
                offset += count
            }
        }
        val floats = FloatArray(sampleCount)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(floats)
        return floats
    }

    private fun replyError(reply: Messenger, requestId: String, code: String, text: String, error: Throwable?) =
        reply(reply, AsrProtocol.ERROR, requestId) {
            putString(AsrProtocol.CODE, code)
            putString(AsrProtocol.MESSAGE, text.take(240))
            putString(AsrProtocol.CAUSE_CLASS, error?.javaClass?.name.orEmpty())
            putInt(AsrProtocol.PID, Process.myPid())
        }

    private fun reply(reply: Messenger, what: Int, requestId: String, fill: Bundle.() -> Unit = {}) {
        runCatching { reply.send(Message.obtain(null, what).apply {
            data = Bundle().apply { putString(AsrProtocol.REQUEST_ID, requestId); fill() }
        }) }
    }

    private fun entry(request: String, stage: String, family: ModelFamily, version: String, cause: String, load: Long, decode: Long) =
        LocalAsrDiagnostics.Entry(request, stage, family.name, version, Process.myPid(), cause, load, decode)

    private data class CachedEngine(
        val family: ModelFamily,
        val root: File,
        val version: String,
        val engine: OfflineTranscriptionEngine
    )

    private data class PreparedRequest(
        val reply: Messenger,
        val requestId: String,
        val family: ModelFamily,
        val root: File,
        val version: String,
        val descriptor: ParcelFileDescriptor,
        val sampleCount: Int
    )

    companion object { private const val MAX_PCM_BYTES = 16L * 1024L * 1024L }
}
