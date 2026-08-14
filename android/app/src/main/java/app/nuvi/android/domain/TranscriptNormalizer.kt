package app.nuvi.android.domain

object TranscriptNormalizer {
    private val whitespace = Regex("\\s+")

    fun normalize(raw: String): String = raw
        .replace("[BLANK_AUDIO]", "", ignoreCase = true)
        .replace("[NO_SPEECH]", "", ignoreCase = true)
        .replace(whitespace, " ")
        .trim()
}
