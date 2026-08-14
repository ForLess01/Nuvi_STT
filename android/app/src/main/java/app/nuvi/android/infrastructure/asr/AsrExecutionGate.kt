package app.nuvi.android.infrastructure.asr

/** Two-phase ownership gate: native work cannot start until the client acknowledges the PID. */
class AsrExecutionGate {
    private var preparedRequest: String? = null
    private var activeRequest: String? = null

    @Synchronized fun prepare(requestId: String): Boolean {
        if (preparedRequest != null || activeRequest != null) return false
        preparedRequest = requestId
        return true
    }

    @Synchronized fun authorize(requestId: String): Boolean {
        if (preparedRequest != requestId || activeRequest != null) return false
        preparedRequest = null
        activeRequest = requestId
        return true
    }

    @Synchronized fun cancel(requestId: String): Boolean {
        val owned = preparedRequest == requestId || activeRequest == requestId
        if (preparedRequest == requestId) preparedRequest = null
        if (activeRequest == requestId) activeRequest = null
        return owned
    }

    @Synchronized fun ownsActive(requestId: String): Boolean = activeRequest == requestId

    @Synchronized fun hasActiveRequest(): Boolean = activeRequest != null

    @Synchronized fun finish(requestId: String) {
        if (activeRequest == requestId) activeRequest = null
    }
}
