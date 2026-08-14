package app.nuvi.android.application

import app.nuvi.android.infrastructure.audio.AudioCaptureHandle
import java.util.concurrent.CompletableFuture

/** Owns exactly one handle. Detached handles cannot observe or mutate later handles. */
class CaptureOwnership {
    private var active: Pair<Long, AudioCaptureHandle>? = null

    @Synchronized fun attach(token: Long, handle: AudioCaptureHandle) {
        check(active == null) { "A capture is already owned" }
        active = token to handle
    }

    /** requestStop is deliberately called before the handle is returned for async work. */
    @Synchronized fun stop(token: Long): CompletableFuture<ShortArray>? {
        val owned = active?.takeIf { it.first == token } ?: return null
        val completion = owned.second.requestStop()
        active = null
        return completion
    }

    @Synchronized fun cancel() {
        val owned = active
        active = null
        owned?.second?.cancel()
    }

    @Synchronized fun cancel(token: Long) {
        val owned = active?.takeIf { it.first == token } ?: return
        active = null
        owned.second.cancel()
    }

    @Synchronized fun isCapturing(token: Long): Boolean =
        active?.takeIf { it.first == token }?.second?.isCapturing == true
}
