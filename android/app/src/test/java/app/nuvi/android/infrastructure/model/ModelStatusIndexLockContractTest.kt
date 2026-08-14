package app.nuvi.android.infrastructure.model

import app.nuvi.android.domain.ModelFamily
import app.nuvi.android.infrastructure.asr.RuntimeLeaseFile
import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.system.measureTimeMillis
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ModelStatusIndexLockContractTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun statusReadsRemainUnder100MsWhileImportJobLockIsHeld() {
        val directory = temporary.newFolder("models")
        val bundle = createParakeetBundle(directory, "parakeet-11111111-1111-1111-1111-111111111111")
        val index = ModelStatusIndex(directory)
        index.replacePointer(ModelFamily.PARAKEET, bundle.name, "seed")
        index.selectFamily(ModelFamily.PARAKEET)

        RandomAccessFile(File(directory, "import.lock"), "rw").use { file ->
            file.channel.lock().use {
                val elapsed = measureTimeMillis {
                    repeat(50) {
                        assertNotNull(index.bundleFor(ModelFamily.PARAKEET))
                        assertTrue(index.hasModel)
                    }
                }
                assertTrue("status reads took ${elapsed}ms", elapsed < 100)
            }
        }
    }

    @Test fun failedProbeCannotReplacePreviousPointer() {
        val directory = temporary.newFolder("models")
        val previous = createParakeetBundle(directory, "parakeet-11111111-1111-1111-1111-111111111111")
        val candidate = createParakeetBundle(directory, "parakeet-22222222-2222-2222-2222-222222222222")
        val index = ModelStatusIndex(directory)
        index.replacePointer(ModelFamily.PARAKEET, previous.name, "seed")

        // A native probe failure never invokes replacePointer(candidate).
        candidate.resolve("encoder.int8.onnx").delete()
        assertEquals(previous.canonicalFile, index.bundleFor(ModelFamily.PARAKEET)!!.root.canonicalFile)
    }

    @Test fun activationJournalRecoversPointerAndSelectedFamilyTogether() {
        val directory = temporary.newFolder("models")
        val candidate = createParakeetBundle(directory, "parakeet-33333333-3333-3333-3333-333333333333")
        val journal = File(directory, "activation-journal.v1")
        journal.writeText("PARAKEET\n${candidate.name}\n33333333-3333-3333-3333-333333333333")

        val recovered = ModelStatusIndex(directory)
        assertTrue(recovered.recoverActivation())
        assertEquals(candidate.canonicalFile, recovered.snapshot()!!.bundle.root.canonicalFile)
        assertEquals(ModelFamily.PARAKEET, recovered.snapshot()!!.family)
        assertFalse(journal.exists())
    }

    @Test fun failedActivationCleanupRecoversPendingCandidateInsteadOfDeletingIt() {
        val directory = temporary.newFolder("failed-activation")
        val candidate = createParakeetBundle(directory, "parakeet-99999999-9999-9999-9999-999999999999")
        File(directory, "activation-journal.v1").writeText(
            "PARAKEET\n${candidate.name}\n99999999-9999-9999-9999-999999999999"
        )
        val index = ModelStatusIndex(directory)

        assertFalse(index.deleteCandidateIfUnpublished(candidate))
        assertTrue(candidate.exists())
        assertEquals(candidate.canonicalFile, index.bundleFor(ModelFamily.PARAKEET)!!.root.canonicalFile)
        assertFalse(File(directory, "activation-journal.v1").exists())
    }

    @Test fun snapshotLeasePublishesBeforeActivationAndCleanupCanDeleteOldBundle() {
        val directory = temporary.newFolder("snapshot-cleanup")
        val previous = createParakeetBundle(directory, "parakeet-44444444-4444-4444-4444-444444444444")
        val replacement = createParakeetBundle(directory, "parakeet-55555555-5555-5555-5555-555555555555")
        val snapshotIndex = ModelStatusIndex(directory)
        val activationIndex = ModelStatusIndex(directory)
        snapshotIndex.replacePointer(ModelFamily.PARAKEET, previous.name, "seed")
        snapshotIndex.selectFamily(ModelFamily.PARAKEET)
        val runtimeLeases = RuntimeLeaseFile(directory) { it == 42 }
        val publisherEntered = CountDownLatch(1)
        val allowPublication = CountDownLatch(1)
        val activationAttempted = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val snapshotFuture = executor.submit<app.nuvi.android.domain.ModelSnapshot?> {
                snapshotIndex.withSnapshotLease { snapshot ->
                    publisherEntered.countDown()
                    assertTrue(allowPublication.await(2, TimeUnit.SECONDS))
                    runtimeLeases.write(42, snapshot.version, snapshot.bundle.root)
                    snapshot
                }
            }
            assertTrue(publisherEntered.await(2, TimeUnit.SECONDS))
            val activationFuture = executor.submit {
                activationAttempted.countDown()
                activationIndex.activateTransactional(ModelFamily.PARAKEET, replacement.name, "replacement") { old ->
                    old?.let { File(directory, ".retired-${it.name}").writeText(it.name) }
                }
            }

            assertTrue(activationAttempted.await(2, TimeUnit.SECONDS))
            Thread.sleep(75)
            assertFalse("activation crossed the snapshot-to-lease window", activationFuture.isDone)
            allowPublication.countDown()
            assertEquals(previous.canonicalFile, snapshotFuture.get(2, TimeUnit.SECONDS)!!.bundle.root.canonicalFile)
            activationFuture.get(2, TimeUnit.SECONDS)

            activationIndex.withStateLock {
                RetiredBundleCleaner.clean(
                    directory,
                    ModelFamily.entries.mapNotNull(activationIndex::activeName).toSet(),
                    runtimeLeases.leasedRootNames()
                )
            }
            assertTrue("published snapshot lease must protect the retired bundle", previous.exists())

            activationIndex.withStateLock {
                runtimeLeases.clear(42)
                RetiredBundleCleaner.clean(
                    directory,
                    ModelFamily.entries.mapNotNull(activationIndex::activeName).toSet(),
                    runtimeLeases.leasedRootNames()
                )
            }
            assertFalse(previous.exists())
        } finally {
            allowPublication.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun activationAndRecoveryShareOneStateLock() {
        val directory = temporary.newFolder("activation-recovery")
        val recoveredCandidate = createParakeetBundle(directory, "parakeet-66666666-6666-6666-6666-666666666666")
        val activatedCandidate = createParakeetBundle(directory, "parakeet-77777777-7777-7777-7777-777777777777")
        File(directory, "activation-journal.v1").writeText(
            "PARAKEET\n${recoveredCandidate.name}\n66666666-6666-6666-6666-666666666666"
        )
        val holder = ModelStatusIndex(directory)
        val activator = ModelStatusIndex(directory)
        val recovery = ModelStatusIndex(directory)
        val lockHeld = CountDownLatch(1)
        val release = CountDownLatch(1)
        val activationAttempted = CountDownLatch(1)
        val recoveryAttempted = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(3)
        try {
            val holderFuture = executor.submit {
                holder.withStateLock {
                    lockHeld.countDown()
                    assertTrue(release.await(2, TimeUnit.SECONDS))
                }
            }
            assertTrue(lockHeld.await(2, TimeUnit.SECONDS))
            val activationFuture = executor.submit {
                activationAttempted.countDown()
                activator.activateTransactional(ModelFamily.PARAKEET, activatedCandidate.name, "activated")
            }
            val recoveryFuture = executor.submit {
                recoveryAttempted.countDown()
                recovery.recoverActivation()
            }

            assertTrue(activationAttempted.await(2, TimeUnit.SECONDS))
            assertTrue(recoveryAttempted.await(2, TimeUnit.SECONDS))
            Thread.sleep(75)
            assertFalse(activationFuture.isDone)
            assertFalse(recoveryFuture.isDone)
            release.countDown()
            holderFuture.get(2, TimeUnit.SECONDS)
            activationFuture.get(2, TimeUnit.SECONDS)
            recoveryFuture.get(2, TimeUnit.SECONDS)

            assertEquals(activatedCandidate.canonicalFile, holder.snapshot()!!.bundle.root.canonicalFile)
            assertFalse(File(directory, "activation-journal.v1").exists())
            assertTrue(directory.listFiles().orEmpty().none { it.name.startsWith(".active-") || it.name.startsWith(".selected-") })
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun publishedCandidateCannotBeCleanedBeforeActivationPointerExists() {
        val directory = temporary.newFolder("publication-cleanup")
        val staging = createParakeetBundle(directory, ".import-88888888-8888-8888-8888-888888888888")
        val candidate = File(directory, "parakeet-88888888-8888-8888-8888-888888888888")
        val publisher = ModelStatusIndex(directory)
        val cleaner = ModelStatusIndex(directory)
        val candidateVisible = CountDownLatch(1)
        val allowActivation = CountDownLatch(1)
        val cleanupAttempted = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val publication = executor.submit {
                publisher.publishAndActivateTransactional(
                    family = ModelFamily.PARAKEET,
                    name = candidate.name,
                    id = "88888888-8888-8888-8888-888888888888",
                    publish = {
                        Files.move(staging.toPath(), candidate.toPath(), StandardCopyOption.ATOMIC_MOVE)
                        candidateVisible.countDown()
                        assertTrue(allowActivation.await(2, TimeUnit.SECONDS))
                    }
                )
            }
            assertTrue(candidateVisible.await(2, TimeUnit.SECONDS))
            val cleanup = executor.submit {
                cleanupAttempted.countDown()
                cleaner.withStateLock {
                    RetiredBundleCleaner.clean(
                        directory,
                        ModelFamily.entries.mapNotNull(cleaner::activeName).toSet(),
                        emptySet()
                    )
                }
            }
            assertTrue(cleanupAttempted.await(2, TimeUnit.SECONDS))
            Thread.sleep(75)
            assertFalse("cleanup entered the publication-to-pointer window", cleanup.isDone)

            allowActivation.countDown()
            publication.get(2, TimeUnit.SECONDS)
            cleanup.get(2, TimeUnit.SECONDS)

            assertEquals(candidate.canonicalFile, publisher.bundleFor(ModelFamily.PARAKEET)!!.root.canonicalFile)
            assertTrue(candidate.exists())
        } finally {
            allowActivation.countDown()
            executor.shutdownNow()
        }
    }

    private fun createParakeetBundle(parent: File, name: String): File = File(parent, name).apply {
        mkdirs()
        listOf("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt").forEach {
            resolve(it).writeText("x")
        }
    }
}
