package app.nuvi.android.domain

object TranscriptionTiming {
    const val CAPTURE_SETTLE_MILLIS = 3_000L
    const val MIN_INFERENCE_MILLIS = 20_000L
    const val MAX_INFERENCE_MILLIS = 90_000L

    fun inferenceDeadlineMillis(samples: Int, sampleRate: Int = 16_000): Long {
        val audioMillis = samples.toLong() * 1_000L / sampleRate.coerceAtLeast(1)
        return (audioMillis * 3L).coerceIn(MIN_INFERENCE_MILLIS, MAX_INFERENCE_MILLIS)
    }
}
