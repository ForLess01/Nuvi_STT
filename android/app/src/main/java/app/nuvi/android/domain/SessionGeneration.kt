package app.nuvi.android.domain

/** Invalidates asynchronous work whenever the editor or recording session changes. */
class SessionGeneration {
    private var value: Long = 0

    @Synchronized fun next(): Long = ++value
    @Synchronized fun current(): Long = value
    @Synchronized fun isCurrent(candidate: Long): Boolean = candidate == value
}
