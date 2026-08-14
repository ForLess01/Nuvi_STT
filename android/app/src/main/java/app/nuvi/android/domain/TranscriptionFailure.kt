package app.nuvi.android.domain

enum class TranscriptionErrorCode {
    CAPTURE_TIMEOUT,
    ENGINE_TIMEOUT,
    MODEL_LOAD_TIMEOUT,
    ENGINE_BUSY,
    CANCELLED,
    NO_SPEECH,
    MODEL_MISSING,
    MODEL_INVALID,
    ENGINE_FAILED,
    IPC_FAILED
}

class TranscriptionFailure(
    val code: TranscriptionErrorCode,
    message: String,
    cause: Throwable? = null
) : Exception("${code.name}: $message", cause)
