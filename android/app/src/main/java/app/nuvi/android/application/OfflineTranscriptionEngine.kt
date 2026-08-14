package app.nuvi.android.application

import app.nuvi.android.domain.ModelFamily
import java.util.concurrent.atomic.AtomicBoolean

interface OfflineTranscriptionEngine : AutoCloseable {
    val family: ModelFamily
    fun transcribe(pcm: FloatArray, cancellation: AtomicBoolean): String
}
