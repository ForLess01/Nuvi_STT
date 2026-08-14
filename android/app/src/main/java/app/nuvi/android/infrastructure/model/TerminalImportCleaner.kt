package app.nuvi.android.infrastructure.model

import java.io.File

/** Candidate-scoped cleanup that revalidates journal ownership under the import-job lock. */
class TerminalImportCleaner(
    directory: File,
    private val jobs: ImportJobGuard = ImportJobGuard(File(directory, "import.lock")),
    private val journals: ImportJournalStore = ImportJournalStore(directory),
    private val deferred: DeferredCandidateCleanup = DeferredCandidateCleanup(directory),
    private val cleanCandidate: (String) -> Int = { OrphanImportCleaner.cleanCandidate(directory, it) }
) {
    fun clean(expectedCandidateId: String): Int {
        if (!deferred.request(expectedCandidateId)) return 0
        return jobs.runIfIdle {
            val current = journals.read()
            deferred.pendingCandidateIds().sumOf { candidateId ->
                if (current?.isActive == true && current.candidateId == candidateId) return@sumOf 0
                runCatching { cleanCandidate(candidateId) }.fold(
                    onSuccess = { removed -> deferred.complete(candidateId); removed },
                    onFailure = { 0 }
                )
            }
        } ?: 0
    }
}
