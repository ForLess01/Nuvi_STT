package app.nuvi.android.infrastructure.model

import java.io.ByteArrayInputStream
import java.io.IOException
import org.junit.Assert.assertTrue
import org.junit.Test

class ParakeetArchiveExtractorTest {
    @Test fun rejectsHugeTokens() = assertRejected("tokens.txt", 2L * 1024L * 1024L + 1, "size limit")
    @Test fun rejectsUnknownFile() = assertRejected("bundle/payload.dat", 10, "unexpected")
    @Test fun rejectsOversizedEncoder() = assertRejected("encoder.int8.onnx", 800L * 1024L * 1024L + 1, "size limit")

    @Test fun rejectsDuplicateRequiredFile() {
        val budget = ParakeetArchiveExtractor.Budget()
        ParakeetArchiveExtractor.inspectEntry(budget, "bundle/tokens.txt", 10, true, false)
        val error = runCatching { ParakeetArchiveExtractor.inspectEntry(budget, "tokens.txt", 10, true, false) }.exceptionOrNull()
        assertTrue(error?.message.orEmpty().contains("duplicate"))
    }

    @Test fun rejectsPathTraversal() = assertRejected("bundle/../tokens.txt", 10, "unsafe")

    @Test fun outerDecompressedStreamLimitCountsParserConsumedBytes() {
        val stream = ParakeetArchiveExtractor.HardLimitInputStream(ByteArrayInputStream(ByteArray(11)), maximumBytes = 10)
        val error = runCatching { stream.readBytes() }.exceptionOrNull()
        assertTrue(error is IOException)
        assertTrue(error?.message.orEmpty().contains("decompressed stream"))
    }

    @Test fun rejectsPositiveSizeDirectoryEntry() {
        val error = runCatching {
            ParakeetArchiveExtractor.inspectEntry(ParakeetArchiveExtractor.Budget(), "bundle/", 1, false, true)
        }.exceptionOrNull()
        assertTrue(error?.message.orEmpty().contains("zero size"))
    }

    @Test fun rejectsTraversalDirectoryBeforeDirectoryHandling() {
        val error = runCatching {
            ParakeetArchiveExtractor.inspectEntry(ParakeetArchiveExtractor.Budget(), "bundle/../escape/", 0, false, true)
        }.exceptionOrNull()
        assertTrue(error?.message.orEmpty().contains("unsafe"))
    }

    private fun assertRejected(name: String, size: Long, message: String) {
        val error = runCatching {
            ParakeetArchiveExtractor.inspectEntry(ParakeetArchiveExtractor.Budget(), name, size, true, false)
        }.exceptionOrNull()
        assertTrue(error?.message.orEmpty().contains(message))
    }
}
