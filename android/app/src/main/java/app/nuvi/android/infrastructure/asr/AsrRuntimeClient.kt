package app.nuvi.android.infrastructure.asr

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import app.nuvi.android.domain.ModelSnapshot
import app.nuvi.android.domain.TranscriptionErrorCode
import app.nuvi.android.domain.TranscriptionFailure
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CompletableFuture

class AsrRuntimeClient(context: Context) : AutoCloseable {
    data class Call(
        val requestId: String,
        val ready: CompletableFuture<Long>,
        val result: CompletableFuture<String>
    )

    private data class Pending(
        val call: Call,
        val snapshot: ModelSnapshot,
        val input: File,
        val sampleCount: Int,
        var remotePid: Int = 0
    )

    private val context = context.applicationContext
    private val diagnostics = LocalAsrDiagnostics(File(this.context.filesDir, "models"))
    private val diagnosticReporter = BestEffortAsrDiagnostics(append = { diagnostics.append(it) })
    private val reply = Messenger(Handler(Looper.getMainLooper(), ::handleReply))
    private var remote: Messenger? = null
    private var remoteBinder: IBinder? = null
    private var pending: Pending? = null
    private var binding = false
    private var closed = false

    private val deathRecipient = IBinder.DeathRecipient { onBinderLost("ASR binder died") }
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder) {
            synchronized(this@AsrRuntimeClient) {
                if (closed) return
                binding = false
                remoteBinder = service
                remote = Messenger(service)
                runCatching { service.linkToDeath(deathRecipient, 0) }
                pending?.let(::sendPrepare)
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) = onBinderLost("ASR service disconnected")
        override fun onBindingDied(name: ComponentName?) = onBinderLost("ASR binding died")
        override fun onNullBinding(name: ComponentName?) = onBinderLost("ASR service returned a null binding")
    }

    @Synchronized fun begin(requestId: String, snapshot: ModelSnapshot, pcm: FloatArray): Call {
        check(!closed) { "ASR client is closed" }
        if (pending != null) throw TranscriptionFailure(TranscriptionErrorCode.ENGINE_BUSY, "Another ASR request is active")
        val input = writePcm(requestId, pcm)
        val call = Call(requestId, CompletableFuture(), CompletableFuture())
        pending = Pending(call, snapshot, input, pcm.size)
        ensureBound()
        remote?.let { sendPrepare(pending!!) }
        return call
    }

    @Synchronized fun abort(requestId: String, code: TranscriptionErrorCode, message: String) {
        val active = pending?.takeIf { it.call.requestId == requestId } ?: return
        val failure = TranscriptionFailure(code, message)
        active.call.ready.completeExceptionally(failure)
        active.call.result.completeExceptionally(failure)
        diagnosticReporter.afterProtocol(
            protocolAction = {
                sendCancel(requestId)
                finish(active)
                resetBinding(stopService = active.remotePid <= 0)
            },
            entry = {
                LocalAsrDiagnostics.Entry(requestId, "client_abort", active.snapshot.family.name,
                    active.snapshot.version, active.remotePid, code.name)
            }
        )
    }

    @Synchronized fun abortActive() {
        pending?.let { abort(it.call.requestId, TranscriptionErrorCode.CANCELLED, "Cancelled") }
    }

    private fun ensureBound() {
        if (remote != null || binding) return
        binding = true
        val bound = context.bindService(Intent(context, AsrRuntimeService::class.java), connection, Context.BIND_AUTO_CREATE)
        if (!bound) {
            binding = false
            onBinderLost("Unable to bind ASR service")
        }
    }

    private fun sendPrepare(value: Pending) {
        val descriptor = ParcelFileDescriptor.open(value.input, ParcelFileDescriptor.MODE_READ_ONLY)
        try {
            remote?.send(Message.obtain(null, AsrProtocol.START).apply {
                replyTo = reply
                data = Bundle().apply {
                    putString(AsrProtocol.REQUEST_ID, value.call.requestId)
                    putString(AsrProtocol.FAMILY, value.snapshot.family.name)
                    putString(AsrProtocol.BUNDLE_ROOT, value.snapshot.bundle.root.absolutePath)
                    putString(AsrProtocol.BUNDLE_VERSION, value.snapshot.version)
                    putParcelable(AsrProtocol.AUDIO_FD, descriptor)
                    putInt(AsrProtocol.SAMPLE_COUNT, value.sampleCount)
                }
            }) ?: error("ASR service is not connected")
        } catch (error: Throwable) {
            onBinderLost(error.message ?: "Unable to send ASR request")
        } finally {
            descriptor.close()
        }
    }

    private fun sendExecute(value: Pending) {
        try {
            remote?.send(Message.obtain(null, AsrProtocol.EXECUTE).apply {
                data = Bundle().apply { putString(AsrProtocol.REQUEST_ID, value.call.requestId) }
            }) ?: error("ASR service is not connected")
        } catch (error: Throwable) {
            onBinderLost(error.message ?: "Unable to authorize ASR request")
        }
    }

    private fun sendCancel(requestId: String) {
        runCatching {
            remote?.send(Message.obtain(null, AsrProtocol.CANCEL).apply {
                data = Bundle().apply { putString(AsrProtocol.REQUEST_ID, requestId) }
            })
        }
    }

    private fun handleReply(message: Message): Boolean {
        val data = message.data
        val requestId = data.getString(AsrProtocol.REQUEST_ID) ?: return true
        synchronized(this) {
            val active = pending?.takeIf { it.call.requestId == requestId } ?: return true
            when (message.what) {
                AsrProtocol.ACCEPTED -> {
                    val pid = data.getInt(AsrProtocol.PID)
                    if (pid <= 0) {
                        onBinderLost("ASR service returned an invalid process ID")
                    } else {
                        active.remotePid = pid
                        // Native work is forbidden until this acknowledgement proves the
                        // dedicated process owns this request and can self-terminate safely.
                        sendExecute(active)
                    }
                }
                AsrProtocol.READY -> {
                    active.remotePid = data.getInt(AsrProtocol.PID, active.remotePid)
                    active.call.ready.complete(data.getLong(AsrProtocol.LOAD_MILLIS))
                }
                AsrProtocol.RESULT -> {
                    active.call.result.complete(data.getString(AsrProtocol.TEXT).orEmpty())
                    finish(active)
                }
                AsrProtocol.ERROR -> {
                    val code = runCatching {
                        TranscriptionErrorCode.valueOf(data.getString(AsrProtocol.CODE).orEmpty())
                    }.getOrDefault(TranscriptionErrorCode.ENGINE_FAILED)
                    val failure = TranscriptionFailure(code, data.getString(AsrProtocol.MESSAGE) ?: "ASR failed")
                    active.call.ready.completeExceptionally(failure)
                    active.call.result.completeExceptionally(failure)
                    finish(active)
                }
            }
        }
        return true
    }

    @Synchronized private fun onBinderLost(message: String) {
        val active = pending
        if (active != null) {
            val failure = TranscriptionFailure(TranscriptionErrorCode.IPC_FAILED, message)
            active.call.ready.completeExceptionally(failure)
            active.call.result.completeExceptionally(failure)
            finish(active)
        }
        resetBinding(stopService = false)
    }

    private fun finish(value: Pending) {
        value.input.delete()
        if (pending === value) pending = null
    }

    private fun resetBinding(stopService: Boolean) {
        remoteBinder?.let { runCatching { it.unlinkToDeath(deathRecipient, 0) } }
        if (remote != null || binding) runCatching { context.unbindService(connection) }
        remote = null
        remoteBinder = null
        binding = false
        if (stopService) context.stopService(Intent(context, AsrRuntimeService::class.java))
    }

    private fun writePcm(requestId: String, pcm: FloatArray): File {
        val directory = File(context.cacheDir, "asr-input").apply { mkdirs() }
        val file = File(directory, "$requestId.pcm")
        val buffer = ByteBuffer.allocate(128 * 1024).order(ByteOrder.LITTLE_ENDIAN)
        FileOutputStream(file).use { output ->
            for (sample in pcm) {
                if (buffer.remaining() < 4) {
                    output.write(buffer.array(), 0, buffer.position())
                    buffer.clear()
                }
                buffer.putFloat(sample)
            }
            if (buffer.position() > 0) output.write(buffer.array(), 0, buffer.position())
            output.fd.sync()
        }
        return file
    }

    @Synchronized override fun close() {
        if (closed) return
        abortActive()
        closed = true
        resetBinding(stopService = true)
    }
}
