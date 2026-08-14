package app.nuvi.android.infrastructure.model

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ImportJobGuardTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun duplicateImportIsRejectedWithoutWaiting() {
        val guard = ImportJobGuard(temporary.newFile("import.lock"))
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        val first = executor.submit { guard.runExclusive { entered.countDown(); release.await(2, TimeUnit.SECONDS) } }
        assertTrue(entered.await(1, TimeUnit.SECONDS))

        val started = System.nanoTime()
        val error = runCatching { guard.runExclusive { error("must not enter") } }.exceptionOrNull() as IOException
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertTrue(elapsedMs < 100)
        assertTrue(error.message!!.startsWith("IMPORT_RUNNING:"))

        release.countDown()
        first.get(1, TimeUnit.SECONDS)
        executor.shutdownNow()
    }

    @Test fun candidateCleanupNeverTouchesAnotherImport() {
        val directory = temporary.newFolder("models")
        directory.resolve(".import-old").mkdirs()
        directory.resolve(".import-new").mkdirs()
        directory.resolve(".import-journal-1").writeText("journal")
        assertEquals(1, OrphanImportCleaner.cleanCandidate(directory, "old"))
        assertTrue(directory.resolve(".import-new").exists())
        assertTrue(directory.resolve(".import-journal-1").exists())
    }

    @Test fun staleTerminalCleanupRevalidatesAgainstNewImportIdentity() {
        val directory = temporary.newFolder("stale-cleanup")
        val journals = ImportJournalStore(directory)
        val jobs = ImportJobGuard(directory.resolve("import.lock"))
        val old = journal("old", ImportStage.FAILED)
        journals.write(old)
        directory.resolve(".import-old").mkdirs()
        val next = journal("new", ImportStage.PREFLIGHT)
        journals.write(next)
        directory.resolve(".import-new").mkdirs()

        val cleaner = TerminalImportCleaner(directory, jobs, journals)
        assertEquals(1, cleaner.clean("old"))
        assertTrue(!directory.resolve(".import-old").exists())
        assertTrue(directory.resolve(".import-new").exists())
    }

    @Test fun terminalCleanupCannotEnterWhileImporterOwnsJobLock() {
        val directory = temporary.newFolder("owned-cleanup")
        val journals = ImportJournalStore(directory)
        val jobs = ImportJobGuard(directory.resolve("import.lock"))
        journals.write(journal("old", ImportStage.FAILED))
        directory.resolve(".import-old").mkdirs()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val owner = executor.submit {
                jobs.runExclusive {
                    entered.countDown()
                    release.await(2, TimeUnit.SECONDS)
                }
            }
            assertTrue(entered.await(1, TimeUnit.SECONDS))

            val cleaner = TerminalImportCleaner(directory, jobs, journals)
            assertEquals(0, cleaner.clean("old"))
            assertTrue(directory.resolve(".import-old").exists())
            assertTrue(DeferredCandidateCleanup(directory).hasPending("old"))

            release.countDown()
            owner.get(1, TimeUnit.SECONDS)
            assertEquals(1, cleaner.clean("old"))
            assertTrue(!DeferredCandidateCleanup(directory).hasPending("old"))
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    private fun journal(candidateId: String, stage: ImportStage) = ImportJournal(
        family = app.nuvi.android.domain.ModelFamily.PARAKEET,
        sourceLabel = "model",
        sourceId = "opaque",
        stage = stage,
        percent = 0,
        startedAtMs = 0,
        updatedAtMs = 0,
        candidateId = candidateId
    )
}
