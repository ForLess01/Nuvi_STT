package app.nuvi.android.domain

import java.io.File

enum class ModelFamily(val displayName: String) {
    PARAKEET("Parakeet"),
    WHISPER("Whisper")
}

sealed interface ModelBundle {
    val family: ModelFamily
    val root: File

    data class Parakeet(override val root: File) : ModelBundle {
        override val family = ModelFamily.PARAKEET
        val encoder get() = File(root, "encoder.int8.onnx")
        val decoder get() = File(root, "decoder.int8.onnx")
        val joiner get() = File(root, "joiner.int8.onnx")
        val tokens get() = File(root, "tokens.txt")
    }

    data class Whisper(val model: File) : ModelBundle {
        override val family = ModelFamily.WHISPER
        override val root get() = model
    }
}

data class ModelSnapshot(
    val family: ModelFamily,
    val bundle: ModelBundle,
    val version: String
)
