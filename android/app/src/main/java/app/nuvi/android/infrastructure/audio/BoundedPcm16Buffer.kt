package app.nuvi.android.infrastructure.audio

/** Fixed-capacity PCM storage. One instance owns at most maxSamples * 2 bytes. */
class BoundedPcm16Buffer(val maxSamples: Int) {
    private val samples = ShortArray(maxSamples)
    private var size = 0

    init { require(maxSamples > 0) }

    @Synchronized
    fun append(source: ShortArray, count: Int): Boolean {
        require(count in 0..source.size)
        val accepted = minOf(count, maxSamples - size)
        source.copyInto(samples, size, 0, accepted)
        size += accepted
        return size == maxSamples
    }

    @Synchronized fun hasSamples(): Boolean = size > 0

    @Synchronized
    fun take(): ShortArray {
        val result = samples.copyOf(size)
        size = 0
        return result
    }

    @Synchronized fun discard() { size = 0 }

    companion object {
        fun toFloat(samples: ShortArray): FloatArray =
            FloatArray(samples.size) { samples[it] / 32768.0f }
    }
}
