package app.nuvi.android.infrastructure.model

/** A service may terminate only itself and only for its currently owned candidate. */
object ImportTerminationGate {
    fun shouldSelfTerminate(running: Boolean, activeCandidateId: String?, requestedCandidateId: String?): Boolean =
        running && !activeCandidateId.isNullOrBlank() && activeCandidateId == requestedCandidateId
}
