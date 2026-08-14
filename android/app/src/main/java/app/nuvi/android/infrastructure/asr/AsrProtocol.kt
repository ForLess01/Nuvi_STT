package app.nuvi.android.infrastructure.asr

internal object AsrProtocol {
    const val START = 1
    const val CANCEL = 2
    const val EXECUTE = 3
    const val ACCEPTED = 10
    const val READY = 11
    const val RESULT = 12
    const val ERROR = 13

    const val REQUEST_ID = "request-id"
    const val FAMILY = "family"
    const val BUNDLE_ROOT = "bundle-root"
    const val BUNDLE_VERSION = "bundle-version"
    const val AUDIO_FD = "audio-fd"
    const val SAMPLE_COUNT = "sample-count"
    const val PID = "pid"
    const val TEXT = "text"
    const val CODE = "code"
    const val MESSAGE = "message"
    const val CAUSE_CLASS = "cause-class"
    const val LOAD_MILLIS = "load-millis"
    const val DECODE_MILLIS = "decode-millis"
}
