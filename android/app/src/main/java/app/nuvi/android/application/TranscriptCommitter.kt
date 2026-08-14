package app.nuvi.android.application

import app.nuvi.android.domain.TranscriptionErrorCode
import app.nuvi.android.domain.TranscriptionFailure

object TranscriptCommitter {
    data class Preconditions(
        val generationCurrent: Boolean,
        val editorSecure: Boolean,
        val connectionPresent: Boolean,
        val connectionCurrent: Boolean
    )

    fun commit(preconditions: Preconditions = Preconditions(true, false, true, true), action: () -> Boolean) {
        when {
            !preconditions.generationCurrent -> stale("request generation is stale")
            preconditions.editorSecure -> stale("editor became secure")
            !preconditions.connectionPresent -> stale("editor connection is missing")
            !preconditions.connectionCurrent -> stale("editor connection changed")
        }
        val accepted = try { action() } catch (error: Throwable) {
            throw TranscriptionFailure(TranscriptionErrorCode.IPC_FAILED, "The active editor rejected the transcript", error)
        }
        if (!accepted) throw TranscriptionFailure(TranscriptionErrorCode.IPC_FAILED, "The active editor rejected the transcript")
    }

    private fun stale(message: String): Nothing =
        throw TranscriptionFailure(TranscriptionErrorCode.IPC_FAILED, "Stale transcript: $message")
}
