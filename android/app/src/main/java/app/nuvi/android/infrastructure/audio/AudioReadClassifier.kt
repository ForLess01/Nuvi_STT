package app.nuvi.android.infrastructure.audio

sealed interface AudioReadOutcome {
    data class Data(val count: Int) : AudioReadOutcome
    data object Retry : AudioReadOutcome
    data class Failure(val code: Int) : AudioReadOutcome
}

object AudioReadClassifier {
    fun classify(count: Int, capacity: Int): AudioReadOutcome = when {
        count in 1..capacity -> AudioReadOutcome.Data(count)
        count == 0 -> AudioReadOutcome.Retry
        else -> AudioReadOutcome.Failure(count)
    }
}
