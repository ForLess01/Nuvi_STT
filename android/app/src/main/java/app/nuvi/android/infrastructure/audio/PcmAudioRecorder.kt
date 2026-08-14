package app.nuvi.android.infrastructure.audio

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.util.concurrent.CancellationException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

sealed class AudioCaptureException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class Unavailable(message: String, cause: Throwable? = null) : AudioCaptureException(message, cause)
    class ReadFailed(val errorCode: Int) : AudioCaptureException("Microphone read failed (AudioRecord code $errorCode)")
}

interface AudioCaptureHandle {
    val isCapturing: Boolean
    fun start()
    /** Immediately requests microphone stop; completion only waits for owned PCM to settle. */
    fun requestStop(): CompletableFuture<ShortArray>
    /** Immediately stops this handle and discards only this handle's PCM. */
    fun cancel()
}

interface AudioCaptureFactory {
    fun create(
        onFailure: (AudioCaptureException) -> Unit,
        onLimitReached: () -> Unit,
        onLevel: (Float) -> Unit = {}
    ): AudioCaptureHandle
}

/** Creates fully independent capture handles; no recorder, buffer, or worker is shared across starts. */
class PcmAudioRecorder(private val context: Context) : AudioCaptureFactory {
    override fun create(
        onFailure: (AudioCaptureException) -> Unit,
        onLimitReached: () -> Unit,
        onLevel: (Float) -> Unit
    ): AudioCaptureHandle {
        check(context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            "Microphone permission is required"
        }
        val minimum = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) throw AudioCaptureException.Unavailable("16 kHz mono recording is unavailable (code $minimum)")
        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minimum * 2, 4096)
            )
        } catch (error: Throwable) {
            throw AudioCaptureException.Unavailable("AudioRecord initialization failed", error)
        }
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            throw AudioCaptureException.Unavailable("AudioRecord initialization failed")
        }
        return AndroidAudioCaptureHandle(recorder, minimum, onFailure, onLimitReached, onLevel)
    }

    private class AndroidAudioCaptureHandle(
        private val recorder: AudioRecord,
        minimumBufferBytes: Int,
        private val onFailure: (AudioCaptureException) -> Unit,
        private val onLimitReached: () -> Unit,
        private val onLevel: (Float) -> Unit
    ) : AudioCaptureHandle {
        private val buffer = BoundedPcm16Buffer(MAX_SAMPLES)
        private val capturing = AtomicBoolean(false)
        private val released = AtomicBoolean(false)
        private val cancelled = AtomicBoolean(false)
        private val completion = CompletableFuture<ShortArray>()
        private val chunkSize = maxOf(minimumBufferBytes / 2, 1024)
        @Volatile private var terminalError: AudioCaptureException? = null

        override val isCapturing: Boolean get() = capturing.get()

        override fun start() {
            try {
                recorder.startRecording()
            } catch (error: Throwable) {
                releaseRecorder()
                throw AudioCaptureException.Unavailable("Microphone recording could not start", error)
            }
            capturing.set(true)
            thread(name = "nuvi-audio-capture", isDaemon = true) { captureLoop() }
        }

        private fun captureLoop() {
            val chunk = ShortArray(chunkSize)
            try {
                while (capturing.get()) {
                    when (val outcome = AudioReadClassifier.classify(
                        recorder.read(chunk, 0, chunk.size, AudioRecord.READ_BLOCKING), chunk.size
                    )) {
                        is AudioReadOutcome.Data -> if (capturing.get()) {
                            publishLevel(chunk, outcome.count)
                            if (buffer.append(chunk, outcome.count)) { requestStop(); onLimitReached() }
                        }
                        AudioReadOutcome.Retry -> Thread.sleep(10)
                        is AudioReadOutcome.Failure -> if (capturing.get()) fail(AudioCaptureException.ReadFailed(outcome.code))
                    }
                }
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
            } catch (error: Throwable) {
                if (capturing.get()) fail(AudioCaptureException.Unavailable("Microphone capture stopped unexpectedly", error))
            } finally {
                releaseRecorder()
                when {
                    cancelled.get() -> {
                        buffer.discard()
                        completion.completeExceptionally(CancellationException("Audio capture cancelled"))
                    }
                    terminalError != null -> {
                        buffer.discard()
                        completion.completeExceptionally(terminalError!!)
                    }
                    else -> completion.complete(buffer.take())
                }
            }
        }

        private fun publishLevel(chunk: ShortArray, count: Int) {
            var sum = 0.0
            for (index in 0 until count) { val value = chunk[index] / 32768.0; sum += value * value }
            onLevel((kotlin.math.sqrt(sum / count.coerceAtLeast(1)) * 5.5).toFloat().coerceIn(0f, 1f))
        }

        override fun requestStop(): CompletableFuture<ShortArray> {
            capturing.set(false)
            releaseRecorder()
            return completion
        }

        override fun cancel() {
            cancelled.set(true)
            capturing.set(false)
            releaseRecorder()
            buffer.discard()
        }

        private fun fail(error: AudioCaptureException) {
            terminalError = error
            capturing.set(false)
            releaseRecorder()
            onFailure(error)
        }

        private fun releaseRecorder() {
            if (!released.compareAndSet(false, true)) return
            runCatching { recorder.stop() }
            recorder.release()
        }
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        const val MAX_DURATION_SECONDS = 120
        const val MAX_SAMPLES = SAMPLE_RATE * MAX_DURATION_SECONDS
    }
}
