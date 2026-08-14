package app.nuvi.android.infrastructure.whisper

import app.nuvi.android.application.OfflineTranscriptionEngine
import app.nuvi.android.domain.ModelFamily
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class WhisperNativeEngine(model: File) : OfflineTranscriptionEngine {
    override val family = ModelFamily.WHISPER
    private var handle: Long

    init {
        require(model.isFile) { "Whisper model does not exist" }
        handle = nativeCreate(model.absolutePath)
        check(handle != 0L) { "Whisper model initialization failed" }
    }

    @Synchronized
    fun transcribe(pcm: FloatArray, language: String = "es", threads: Int = DEFAULT_THREADS): String {
        check(handle != 0L) { "Whisper engine is closed" }
        require(pcm.isNotEmpty()) { "Audio is empty" }
        return nativeTranscribe(handle, pcm, threads.coerceIn(1, 8), language)
    }

    @Synchronized
    override fun transcribe(pcm: FloatArray, cancellation: AtomicBoolean): String {
        check(!cancellation.get()) { "Transcription cancelled" }
        nativeResetCancellation(handle)
        val watcher = CancellationWatcher(cancellation, { nativeCancel(handle) })
        return try { transcribe(pcm) } finally { watcher.close() }
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) {
            nativeDestroy(handle)
            handle = 0L
        }
    }

    private external fun nativeCreate(modelPath: String): Long
    private external fun nativeTranscribe(handle: Long, pcm: FloatArray, threads: Int, language: String): String
    private external fun nativeCancel(handle: Long)
    private external fun nativeResetCancellation(handle: Long)
    private external fun nativeDestroy(handle: Long)

    companion object {
        // Six workers leave two Snapdragon 8 Gen 3 CPU cores free for the IME and foreground app.
        const val DEFAULT_THREADS = 6
        init { System.loadLibrary("nuvi_whisper") }
    }
}
