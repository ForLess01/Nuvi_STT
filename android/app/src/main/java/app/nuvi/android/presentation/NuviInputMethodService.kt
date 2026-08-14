package app.nuvi.android.presentation

import android.content.Intent
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import app.nuvi.android.R
import app.nuvi.android.application.DictationSessionController
import app.nuvi.android.application.TranscriptCommitter
import app.nuvi.android.domain.ModelFamily
import app.nuvi.android.domain.SecureEditorClassifier
import app.nuvi.android.infrastructure.model.ModelStore

class NuviInputMethodService : InputMethodService() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var controller: DictationSessionController
    private lateinit var stateLabel: TextView
    private lateinit var engineBadge: TextView
    private lateinit var statusText: TextView
    private lateinit var ferrofluid: FerrofluidView
    private lateinit var cancelButton: Button
    private var editorInfo: EditorInfo? = null
    private var recordingToken: Long? = null
    private var recordingConnection: InputConnection? = null
    private var phaseStarted = 0L
    private var busy = false

    override fun onCreate() { super.onCreate(); controller = DictationSessionController(this) }

    override fun onCreateInputView(): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        setPadding(dp(16), dp(10), dp(16), dp(10))
        setBackgroundColor(getColor(R.color.ime_surface))

        addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            stateLabel = context.textLabel(getString(R.string.state_ready), 15f, true)
            addView(stateLabel, LinearLayout.LayoutParams(0, dp(36), 1f).apply { gravity = Gravity.CENTER_VERTICAL })
            engineBadge = context.badge(getString(R.string.engine_badge, ModelFamily.PARAKEET.displayName.uppercase()))
            addView(engineBadge, LinearLayout.LayoutParams(-2, dp(28)))
            addView(context.textLabel(getString(R.string.action_switch), 13f, true).apply {
                gravity = Gravity.CENTER; minWidth = dp(64); minHeight = dp(48); isClickable = true
                setOnClickListener { switchKeyboard() }
            }, LinearLayout.LayoutParams(dp(72), dp(48)).apply { leftMargin = dp(6) })
        }, LinearLayout.LayoutParams(-1, dp(48)))

        addView(FrameLayout(context).apply {
            ferrofluid = FerrofluidView(context).apply {
                contentDescription = getString(R.string.action_start_dictation)
                isClickable = true; isFocusable = true
                setOnClickListener { toggleDictation() }
            }
            addView(ferrofluid, FrameLayout.LayoutParams(dp(80), dp(80), Gravity.CENTER))
        }, LinearLayout.LayoutParams(-1, dp(84)))

        statusText = context.textLabel(getString(R.string.status_idle), 13f).apply {
            gravity = Gravity.CENTER
            setTextColor(getColor(R.color.content_secondary))
        }
        addView(statusText, LinearLayout.LayoutParams(-1, dp(30)))

        cancelButton = context.primaryButton(getString(R.string.action_cancel)) { cancelTranscription() }.apply {
            contentDescription = getString(R.string.action_cancel_transcription)
            visibility = View.INVISIBLE
        }
        addView(cancelButton, LinearLayout.LayoutParams(-1, dp(48)))
        refreshAvailability()
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        editorInfo = attribute
        invalidateSession()
        if (::ferrofluid.isInitialized) {
            ferrofluid.refreshRenderingPolicy()
            refreshAvailability()
        }
    }

    override fun onFinishInput() { invalidateSession(); editorInfo = null; super.onFinishInput() }

    private fun toggleDictation() {
        if (busy) return
        recordingToken?.let(::stopDictation) ?: startDictation()
    }

    private fun startDictation() {
        if (SecureEditorClassifier.isSecure(editorInfo)) return
        try {
            recordingConnection = currentInputConnection ?: error("IPC_FAILED: No editable field is active")
            recordingToken = controller.start(::renderState, { limited -> mainHandler.post { if (recordingToken == limited) stopDictation(limited) } }) { level ->
                mainHandler.post { if (::ferrofluid.isInitialized) ferrofluid.setNormalizedLevel(level) }
            }
        } catch (error: Throwable) {
            recordingConnection = null; recordingToken = null
            showError(error.message ?: "ENGINE_FAILED: Unable to start dictation")
        }
    }

    private fun stopDictation(token: Long) {
        val connection = recordingConnection
        recordingToken = null
        busy = true
        controller.stopAndTranscribe(token, ::renderState) { completedToken, text ->
            mainHandler.post {
                val preconditions = TranscriptCommitter.Preconditions(
                    generationCurrent = controller.isCurrent(completedToken),
                    editorSecure = SecureEditorClassifier.isSecure(editorInfo),
                    connectionPresent = connection != null,
                    connectionCurrent = connection != null && connection === currentInputConnection
                )
                val committed = runCatching {
                    TranscriptCommitter.commit(preconditions) { connection!!.commitText(text, 1) }
                }.onFailure { recoverCommitFailure(it.message ?: getString(R.string.error_editor_rejected)) }.isSuccess
                if (committed) mainHandler.postDelayed({ busy = false; recordingConnection = null; refreshAvailability() }, 230L)
            }
        }
    }

    private fun renderState(state: DictationSessionController.State) {
        mainHandler.post {
            if (!::stateLabel.isInitialized) return@post
            val model = when (state) {
                is DictationSessionController.State.LoadingModel -> state.family
                is DictationSessionController.State.Transcribing -> state.family
                else -> ModelStore(this).selectedFamily
            }
            engineBadge.text = getString(R.string.engine_badge, model.displayName.uppercase())
            when (state) {
                DictationSessionController.State.Idle -> { stateLabel.text = getString(R.string.state_ready); statusText.text = getString(R.string.status_idle); ferrofluid.contentDescription = getString(R.string.action_start_dictation); ferrofluid.setMotionState(FerrofluidView.MotionState.IDLE); busy = false }
                DictationSessionController.State.Recording -> { stateLabel.text = getString(R.string.state_listening); statusText.text = getString(R.string.status_recording); ferrofluid.contentDescription = getString(R.string.action_stop_dictation); ferrofluid.setMotionState(FerrofluidView.MotionState.RECORDING); cancelButton.visibility = View.VISIBLE }
                is DictationSessionController.State.FinishingCapture -> showTimedPhase(getString(R.string.phase_finishing), FerrofluidView.MotionState.TRANSCRIBING)
                is DictationSessionController.State.LoadingModel -> showTimedPhase(getString(R.string.phase_loading), FerrofluidView.MotionState.TRANSCRIBING)
                is DictationSessionController.State.Transcribing -> showTimedPhase(getString(R.string.phase_transcribing), FerrofluidView.MotionState.TRANSCRIBING)
                DictationSessionController.State.Success -> { stateLabel.text = getString(R.string.state_inserted); statusText.text = getString(R.string.status_complete); cancelButton.visibility = View.INVISIBLE; ferrofluid.contentDescription = getString(R.string.action_start_dictation); ferrofluid.setMotionState(FerrofluidView.MotionState.SUCCESS) }
                is DictationSessionController.State.Error -> showError("${state.code.name}: ${state.message.substringAfter(": ", state.message)}")
            }
        }
    }

    private fun showTimedPhase(label: String, animation: FerrofluidView.MotionState) {
        if (stateLabel.text != label) phaseStarted = SystemClock.elapsedRealtime()
        stateLabel.text = label
        statusText.text = getString(R.string.status_elapsed, (SystemClock.elapsedRealtime() - phaseStarted) / 1000)
        ferrofluid.contentDescription = getString(R.string.action_transcription_busy)
        ferrofluid.setMotionState(animation)
        cancelButton.visibility = View.VISIBLE
        mainHandler.postDelayed({ if (busy && stateLabel.text == label) showTimedPhase(label, animation) }, 1_000L)
    }

    private fun cancelTranscription() {
        controller.cancel(::renderState)
        recordingToken = null; recordingConnection = null; busy = false
        cancelButton.visibility = View.INVISIBLE
        refreshAvailability()
    }

    private fun refreshAvailability() {
        val secure = SecureEditorClassifier.isSecure(editorInfo)
        val store = ModelStore(this)
        engineBadge.text = getString(R.string.engine_badge, store.selectedFamily.displayName.uppercase())
        ferrofluid.isEnabled = !secure && store.hasModel
        ferrofluid.alpha = if (ferrofluid.isEnabled) 1f else .45f
        stateLabel.text = when { secure -> getString(R.string.state_secure); !store.hasModel -> getString(R.string.state_model_required); else -> getString(R.string.state_ready) }
        statusText.text = when {
            secure -> getString(R.string.status_secure)
            !store.hasModel -> getString(R.string.status_model_required, store.selectedFamily.displayName)
            else -> getString(R.string.status_idle)
        }
        ferrofluid.contentDescription = when { secure -> getString(R.string.action_secure_locked); !store.hasModel -> getString(R.string.state_model_required); else -> getString(R.string.action_start_dictation) }
        ferrofluid.setMotionState(if (secure) FerrofluidView.MotionState.LOCKED else FerrofluidView.MotionState.IDLE)
        if (!store.hasModel) ferrofluid.setOnLongClickListener {
            startActivity(Intent(this, SetupActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true
        }
    }

    private fun showError(message: String) {
        recordingConnection = null
        recordingToken = null
        busy = false
        stateLabel.text = getString(R.string.state_error)
        statusText.text = message
        cancelButton.visibility = View.INVISIBLE
        ferrofluid.setMotionState(FerrofluidView.MotionState.ERROR)
    }

    private fun recoverCommitFailure(message: String) {
        showError(message)
        mainHandler.postDelayed({ if (!busy && recordingToken == null) refreshAvailability() }, COMMIT_ERROR_DISPLAY_MILLIS)
    }

    private fun invalidateSession() { if (::controller.isInitialized) controller.invalidate(); recordingToken = null; recordingConnection = null; busy = false; if (::ferrofluid.isInitialized) ferrofluid.setMotionState(FerrofluidView.MotionState.IDLE) }
    private fun switchKeyboard() { if (android.os.Build.VERSION.SDK_INT >= 28) switchToNextInputMethod(false) else (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showInputMethodPicker() }
    override fun onDestroy() { invalidateSession(); controller.close(); super.onDestroy() }
    override fun onFinishInputView(finishingInput: Boolean) { invalidateSession(); super.onFinishInputView(finishingInput) }
    override fun onWindowHidden() { invalidateSession(); super.onWindowHidden() }
    override fun onWindowShown() { super.onWindowShown(); if (::ferrofluid.isInitialized) ferrofluid.refreshRenderingPolicy() }

    companion object { private const val COMMIT_ERROR_DISPLAY_MILLIS = 1_200L }
}
