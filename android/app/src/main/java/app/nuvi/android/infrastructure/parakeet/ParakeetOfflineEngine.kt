package app.nuvi.android.infrastructure.parakeet

import android.content.res.AssetManager
import app.nuvi.android.application.OfflineTranscriptionEngine
import app.nuvi.android.domain.ModelBundle
import app.nuvi.android.domain.ModelFamily
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig
import java.util.concurrent.atomic.AtomicBoolean

class ParakeetOfflineEngine(
    bundle: ModelBundle.Parakeet,
    threads: Int = DEFAULT_THREADS
) : OfflineTranscriptionEngine {
    override val family = ModelFamily.PARAKEET
    private val recognizer: OfflineRecognizer

    init {
        ParakeetBundleValidator.validate(bundle)
        val transducer = OfflineTransducerModelConfig().apply {
            encoder = bundle.encoder.absolutePath
            decoder = bundle.decoder.absolutePath
            joiner = bundle.joiner.absolutePath
        }
        val model = OfflineModelConfig().apply {
            this.transducer = transducer
            tokens = bundle.tokens.absolutePath
            numThreads = threads.coerceIn(2, 6)
            debug = false
            provider = "cpu"
            modelType = "nemo_transducer"
        }
        val config = OfflineRecognizerConfig().apply {
            featConfig = FeatureConfig().apply {
                sampleRate = SAMPLE_RATE
                featureDim = 80
                dither = 0f
            }
            modelConfig = model
            decodingMethod = "greedy_search"
            maxActivePaths = 4
        }
        // Imported models live in app-private files, not APK assets. sherpa-onnx selects
        // newFromFile only when AssetManager is null; passing context.assets with absolute
        // paths selects newFromAsset and makes a valid imported bundle unloadable.
        recognizer = ImportedModelFactory.create<AssetManager, OfflineRecognizerConfig, OfflineRecognizer>(config) {
                assetManager, recognizerConfig -> OfflineRecognizer(assetManager, recognizerConfig)
        }
    }

    override fun transcribe(pcm: FloatArray, cancellation: AtomicBoolean): String {
        check(!cancellation.get()) { "Transcription cancelled" }
        val stream = recognizer.createStream()
        return try {
            stream.acceptWaveform(pcm, SAMPLE_RATE)
            check(!cancellation.get()) { "Transcription cancelled" }
            recognizer.decode(stream)
            check(!cancellation.get()) { "Transcription cancelled" }
            recognizer.getResult(stream).text
        } finally {
            stream.release()
        }
    }

    override fun close() = recognizer.release()

    companion object {
        const val DEFAULT_THREADS = 2
        const val SAMPLE_RATE = 16_000
    }
}
