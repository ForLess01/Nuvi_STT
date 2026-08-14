package app.nuvi.android.application

import app.nuvi.android.domain.TranscriptionErrorCode
import app.nuvi.android.domain.TranscriptionFailure
import org.junit.Assert.assertEquals
import org.junit.Test

class TranscriptCommitterTest {
    @Test fun falseCommitBecomesIpcFailure() {
        val failure = runCatching { TranscriptCommitter.commit { false } }.exceptionOrNull() as TranscriptionFailure
        assertEquals(TranscriptionErrorCode.IPC_FAILED, failure.code)
    }

    @Test fun commitExceptionBecomesIpcFailure() {
        val failure = runCatching { TranscriptCommitter.commit { error("dead binder") } }.exceptionOrNull() as TranscriptionFailure
        assertEquals(TranscriptionErrorCode.IPC_FAILED, failure.code)
    }

    @Test fun acceptedCommitSucceeds() { TranscriptCommitter.commit { true } }

    @Test fun staleGenerationNeverCallsCommit() = assertInvalid(TranscriptCommitter.Preconditions(false, false, true, true))
    @Test fun secureEditorNeverCallsCommit() = assertInvalid(TranscriptCommitter.Preconditions(true, true, true, true))
    @Test fun missingConnectionNeverCallsCommit() = assertInvalid(TranscriptCommitter.Preconditions(true, false, false, false))
    @Test fun changedConnectionNeverCallsCommit() = assertInvalid(TranscriptCommitter.Preconditions(true, false, true, false))

    private fun assertInvalid(preconditions: TranscriptCommitter.Preconditions) {
        var called = false
        val failure = runCatching { TranscriptCommitter.commit(preconditions) { called = true; true } }.exceptionOrNull() as TranscriptionFailure
        assertEquals(false, called)
        assertEquals(TranscriptionErrorCode.IPC_FAILED, failure.code)
    }
}
