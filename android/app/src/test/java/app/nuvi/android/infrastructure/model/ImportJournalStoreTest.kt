package app.nuvi.android.infrastructure.model

import app.nuvi.android.domain.ModelFamily
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ImportJournalStoreTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun journalSurvivesCoordinatorRecreationWithoutSensitiveUri() {
        val directory = temporary.newFolder("models")
        val first = ImportJournalStore(directory)
        val journal = sample().copy(sourceLabel = "Parakeet v3.tar.bz2", sourceId = "opaque-sha256")
        first.write(journal)

        val restored = ImportJournalStore(directory).read()!!
        assertEquals(journal, restored)
        assertFalse(directory.resolve("import-journal.v1").readText().contains("content://"))
    }

    @Test fun abandonedActiveJournalBecomesInterruptedAndKeepsIdentity() {
        val store = ImportJournalStore(temporary.newFolder("models"))
        store.write(sample())
        val recovered = store.recoverInterrupted(5_000, activeProcessOwnsJob = false)!!
        assertEquals(ImportStage.INTERRUPTED, recovered.stage)
        assertEquals("IMPORT_INTERRUPTED", recovered.errorCode)
        assertEquals("candidate", recovered.candidateId)
        assertFalse(recovered.isActive)
    }

    @Test fun liveImportIsNotMisclassifiedAsInterrupted() {
        val store = ImportJournalStore(temporary.newFolder("models"))
        store.write(sample())
        assertTrue(store.recoverInterrupted(5_000, activeProcessOwnsJob = true)!!.isActive)
    }

    @Test fun firstTerminalStateWinsForSameCandidate() {
        val store = ImportJournalStore(temporary.newFolder("models"))
        val failed = sample().copy(stage = ImportStage.FAILED, errorCode = "MODEL_LOAD_TIMEOUT")
        assertEquals(failed, store.write(failed))
        val cancelled = failed.copy(stage = ImportStage.CANCELLED, errorCode = "IMPORT_CANCELLED")
        assertEquals(failed, store.write(cancelled))
        assertEquals("MODEL_LOAD_TIMEOUT", store.read()!!.errorCode)
    }

    @Test fun newCandidateCanStartAfterPreviousTerminalState() {
        val store = ImportJournalStore(temporary.newFolder("models"))
        store.write(sample().copy(stage = ImportStage.FAILED, errorCode = "MODEL_LOAD_TIMEOUT"))
        val next = sample().copy(candidateId = "next", stage = ImportStage.PREFLIGHT, errorCode = null)
        assertEquals(next, store.write(next))
        assertTrue(store.read()!!.isActive)
    }

    @Test fun lateTerminalFromOldCandidateCannotOverwriteNewImport() {
        val store = ImportJournalStore(temporary.newFolder("models"))
        val old = sample().copy(stage = ImportStage.FAILED, errorCode = "MODEL_LOAD_TIMEOUT")
        store.write(old)
        val next = sample().copy(candidateId = "next", stage = ImportStage.PREFLIGHT, errorCode = null)
        store.write(next)
        store.write(old.copy(updatedAtMs = 99_000L))
        assertEquals("next", store.read()!!.candidateId)
        assertTrue(store.read()!!.isActive)
    }

    private fun sample() = ImportJournal(
        family = ModelFamily.PARAKEET,
        sourceLabel = "model",
        sourceId = "opaque",
        stage = ImportStage.EXTRACTING,
        percent = 42,
        startedAtMs = 1_000,
        updatedAtMs = 2_000,
        candidateId = "candidate"
    )
}
