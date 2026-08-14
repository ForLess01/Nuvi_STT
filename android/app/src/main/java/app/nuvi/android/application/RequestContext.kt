package app.nuvi.android.application

import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

data class RequestContext(
    val id: String,
    val generation: Long,
    val cancellation: AtomicBoolean,
    val deadlineAtMillis: Long
) {
    fun cancel() = cancellation.set(true)
    val isCancelled get() = cancellation.get()

    companion object {
        fun create(generation: Long, nowMillis: Long, maximumLifetimeMillis: Long): RequestContext =
            RequestContext(UUID.randomUUID().toString(), generation, AtomicBoolean(false), nowMillis + maximumLifetimeMillis)
    }
}

class RequestOwnership {
    private var active: RequestContext? = null

    @Synchronized fun replace(context: RequestContext): RequestContext? {
        val previous = active
        active = context
        previous?.cancel()
        return previous
    }
    @Synchronized fun current(): RequestContext? = active
    @Synchronized fun isActive(context: RequestContext): Boolean = active === context
    @Synchronized fun owns(context: RequestContext): Boolean = active === context && !context.isCancelled
    @Synchronized fun ifOwned(context: RequestContext, action: () -> Unit): Boolean {
        if (active !== context || context.isCancelled) return false
        action()
        return true
    }
    @Synchronized fun ifActive(context: RequestContext, action: () -> Unit): Boolean {
        if (active !== context) return false
        action()
        return true
    }
    @Synchronized fun cancel(context: RequestContext) {
        context.cancel()
        if (active === context) active = null
    }
    @Synchronized fun cancelActive(): RequestContext? {
        val previous = active
        active = null
        previous?.cancel()
        return previous
    }
}
