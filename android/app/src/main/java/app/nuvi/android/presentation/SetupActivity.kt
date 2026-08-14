package app.nuvi.android.presentation

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.Window
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import app.nuvi.android.R
import app.nuvi.android.application.ModelImportCoordinator
import app.nuvi.android.application.ImeStatusResolver
import app.nuvi.android.application.ImeStatusResolver.Check
import app.nuvi.android.domain.ModelBundle
import app.nuvi.android.domain.ModelFamily
import app.nuvi.android.infrastructure.model.ModelStore
import java.io.File

class SetupActivity : Activity() {
    private lateinit var modelStore: ModelStore
    private lateinit var readiness: TextView
    private lateinit var modelStatus: TextView
    private lateinit var importProgress: ProgressBar
    private lateinit var primaryAction: TextView
    private lateinit var cancelImport: TextView
    private lateinit var setupFerrofluid: FerrofluidView
    private lateinit var importCoordinator: ModelImportCoordinator
    private var importObservation: AutoCloseable? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        if (Build.VERSION.SDK_INT >= 30) window.setDecorFitsSystemWindows(false)
        modelStore = ModelStore(this)
        importCoordinator = ModelImportCoordinator.get(applicationContext)
        setContentView(createContent())
    }

    override fun onStart() {
        super.onStart()
        importObservation = importCoordinator.observe(::onImportState)
    }

    override fun onStop() {
        importObservation?.close()
        importObservation = null
        super.onStop()
    }

    override fun onResume() { super.onResume(); renderStatus() }

    private fun createContent(): FrameLayout = FrameLayout(this).apply {
        setBackgroundColor(getColor(R.color.surface))
        val content = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(
                dp(SetupLayoutMetrics.CONTENT_HORIZONTAL_PADDING_DP),
                dp(SetupLayoutMetrics.CONTENT_TOP_PADDING_DP),
                dp(SetupLayoutMetrics.CONTENT_HORIZONTAL_PADDING_DP),
                dp(120)
            )

            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(context.textLabel(getString(R.string.app_name), 28f, true), LinearLayout.LayoutParams(0, -2, 1f))
                addView(context.badge(getString(R.string.offline_badge)), LinearLayout.LayoutParams(-2, dp(30)))
            }, matchWrap())

            setupFerrofluid = FerrofluidView(context).apply { contentDescription = getString(R.string.setup_ferrofluid_description) }
            addView(setupFerrofluid, LinearLayout.LayoutParams(-1, dp(SetupLayoutMetrics.HERO_HEIGHT_DP)).apply {
                topMargin = dp(18); bottomMargin = dp(12)
            })
            addView(context.textLabel(getString(R.string.setup_privacy_title), 22f, true).apply { gravity = Gravity.CENTER }, matchWrap())
            addView(context.textLabel(getString(R.string.setup_privacy_body), 14f).apply {
                gravity = Gravity.CENTER
                setTextColor(getColor(R.color.content_secondary))
            }, matchWrap().apply { topMargin = dp(8); bottomMargin = dp(22) })

            addSection(getString(R.string.setup_readiness)) {
                readiness = context.textLabel(getString(R.string.setup_checking), 14f)
                addView(readiness, matchWrap())
            }

            addSection(getString(R.string.setup_engine)) {
                addView(context.textLabel(getString(R.string.setup_engine_help), 13f).apply {
                    setTextColor(getColor(R.color.content_secondary))
                }, matchWrap().apply { bottomMargin = dp(10) })
                addView(RadioGroup(context).apply {
                    orientation = RadioGroup.HORIZONTAL
                    val selected = modelStore.selectedFamily
                    ModelFamily.entries.forEach { family ->
                        addView(RadioButton(context).apply {
                            id = View.generateViewId(); text = family.displayName; tag = family; isChecked = selected == family
                            minHeight = dp(48)
                        }, LinearLayout.LayoutParams(0, dp(48), 1f))
                    }
                    setOnCheckedChangeListener { group, checked ->
                        (group.findViewById<RadioButton>(checked).tag as? ModelFamily)?.let {
                            modelStore.selectFamily(it); renderStatus()
                        }
                    }
                }, matchWrap())
            }

            addSection(getString(R.string.setup_local_model)) {
                modelStatus = context.textLabel(getString(R.string.setup_no_model), 14f, true)
                addView(modelStatus, matchWrap())
                importProgress = ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal).apply {
                    max = 100; visibility = View.GONE
                }
                addView(importProgress, matchWrap().apply { topMargin = dp(10) })
                addView(context.primaryButton(getString(R.string.setup_import_downloads)) { selectModel() }, matchWrap().apply { topMargin = dp(12) })
                cancelImport = context.primaryButton(getString(R.string.action_cancel_import)) { importCoordinator.cancel() }.apply {
                    visibility = View.GONE
                }
                addView(cancelImport, matchWrap().apply { topMargin = dp(8) })
                addView(context.textLabel(getString(R.string.setup_model_help), 12f).apply {
                    setTextColor(getColor(R.color.content_secondary))
                }, matchWrap().apply { topMargin = dp(8) })
            }
        }
        val scroll = ScrollView(context).apply {
            isFillViewport = true
            clipToPadding = false
            addView(content)
        }
        addView(scroll, FrameLayout.LayoutParams(-1, -1))

        val dock = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background = context.opticalGlassDrawable()
            elevation = dp(12).toFloat()
            primaryAction = context.primaryButton(getString(R.string.setup_continue)) { performPrimaryAction() }
            addView(primaryAction, LinearLayout.LayoutParams(-1, dp(52)))
        }
        addView(dock, FrameLayout.LayoutParams(-1, dp(76), Gravity.BOTTOM).apply {
            leftMargin = dp(16); rightMargin = dp(16); bottomMargin = dp(18)
        })
        setOnApplyWindowInsetsListener { root, insets ->
            val top: Int
            val bottom: Int
            if (Build.VERSION.SDK_INT >= 30) {
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                top = bars.top; bottom = bars.bottom
            } else {
                @Suppress("DEPRECATION") top = insets.systemWindowInsetTop
                @Suppress("DEPRECATION") bottom = insets.systemWindowInsetBottom
            }
            root.setPadding(0, 0, 0, 0)
            scroll.setPadding(0, top, 0, 0)
            content.setPadding(
                dp(SetupLayoutMetrics.CONTENT_HORIZONTAL_PADDING_DP),
                dp(SetupLayoutMetrics.CONTENT_TOP_PADDING_DP),
                dp(SetupLayoutMetrics.CONTENT_HORIZONTAL_PADDING_DP),
                dp(120) + bottom
            )
            (dock.layoutParams as FrameLayout.LayoutParams).apply { bottomMargin = dp(18) + bottom; dock.layoutParams = this }
            insets
        }
        requestApplyInsets()
    }

    private fun LinearLayout.addSection(title: String, block: LinearLayout.() -> Unit) {
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
            background = context.roundedSurface(22)
            addView(context.textLabel(title, 16f, true), matchWrap().apply { bottomMargin = dp(10) })
            block()
        }, matchWrap().apply { bottomMargin = dp(12) })
    }

    private fun requestMicrophone() {
        if (!microphoneGranted()) requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MICROPHONE_REQUEST)
    }

    private fun selectModel() {
        if (importCoordinator.isRunning()) {
            if (::modelStatus.isInitialized) modelStatus.text = getString(R.string.model_import_running)
            return
        }
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/octet-stream"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/octet-stream", "application/x-bzip2", "application/x-tar"))
        }, MODEL_REQUEST)
    }

    @Deprecated("Kept dependency-free for the minimum Android slice")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != MODEL_REQUEST || resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        runCatching {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (!importCoordinator.start(uri)) modelStatus.text = getString(R.string.model_import_running)
    }

    private fun renderStatus() {
        if (!::readiness.isInitialized) return
        val ime = queryImeStatus()
        readiness.text = listOf(
            checkLine(microphoneGranted(), getString(R.string.readiness_microphone)),
            checkLine(modelStore.hasModel, getString(R.string.readiness_model, modelStore.selectedFamily.displayName)),
            checkLine(ime.enabled, if (ime.enabled == Check.UNKNOWN) getString(R.string.readiness_enabled_unknown) else getString(R.string.readiness_enabled)),
            checkLine(ime.selected, if (ime.selected == Check.UNKNOWN) getString(R.string.readiness_selected_unknown) else getString(R.string.readiness_selected))
        ).joinToString("\n")
        modelStatus.text = modelStore.activeBundle?.let { getString(R.string.model_ready, it.family.displayName, bundleSizeMb(it)) }
            ?: getString(R.string.model_required_for, modelStore.selectedFamily.displayName)
        primaryAction.text = when {
            !microphoneGranted() -> getString(R.string.action_allow_microphone)
            !modelStore.hasModel -> getString(R.string.action_import_model, modelStore.selectedFamily.displayName)
            ime.enabled == Check.NO -> getString(R.string.action_enable_keyboard)
            ime.enabled == Check.UNKNOWN -> getString(R.string.action_open_keyboard_settings)
            ime.selected == Check.NO -> getString(R.string.action_select_keyboard)
            ime.selected == Check.UNKNOWN -> getString(R.string.action_check_keyboard)
            else -> getString(R.string.action_ready)
        }
        primaryAction.isEnabled = !(microphoneGranted() && modelStore.hasModel && ime.enabled == Check.YES && ime.selected == Check.YES)
        renderImportState(importCoordinator.state())
    }

    private fun performPrimaryAction() = when {
        !microphoneGranted() -> requestMicrophone()
        !modelStore.hasModel -> selectModel()
        queryImeStatus().enabled != Check.YES -> startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        queryImeStatus().selected != Check.YES -> (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showInputMethodPicker()
        else -> Unit
    }

    private fun microphoneGranted() = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    private fun queryImeStatus(): ImeStatusResolver.Snapshot {
        val manager = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
        val enabled = runCatching { manager.enabledInputMethodList.map { it.serviceInfo.packageName } }
        val current = if (Build.VERSION.SDK_INT >= 34) {
            runCatching { manager.currentInputMethodInfo?.serviceInfo?.packageName }
        } else null
        return ImeStatusResolver.resolve(packageName, enabled, current)
    }
    private fun checkLine(ready: Boolean, label: String) = getString(if (ready) R.string.readiness_complete else R.string.readiness_incomplete, label)
    private fun checkLine(state: Check, label: String) = getString(when (state) {
        Check.YES -> R.string.readiness_complete
        Check.NO -> R.string.readiness_incomplete
        Check.UNKNOWN -> R.string.readiness_unknown
    }, label)
    private fun bundleSizeMb(bundle: ModelBundle): Long = if (bundle.root.isDirectory) bundle.root.walkTopDown().filter(File::isFile).sumOf(File::length) / 1_048_576L else bundle.root.length() / 1_048_576L
    private fun matchWrap() = LinearLayout.LayoutParams(-1, -2)
    private fun renderImportState(state: ModelImportCoordinator.State) {
        if (!::modelStatus.isInitialized || isFinishing || isDestroyed) return
        when (state) {
            ModelImportCoordinator.State.Idle -> {
                importProgress.visibility = View.GONE
                cancelImport.visibility = View.GONE
                setupFerrofluid.setMotionState(FerrofluidView.MotionState.IDLE)
            }
            is ModelImportCoordinator.State.Running -> {
                importProgress.visibility = View.VISIBLE
                importProgress.progress = state.progress
                cancelImport.visibility = View.VISIBLE
                modelStatus.text = getString(
                    R.string.model_import_stage_progress,
                    importStageLabel(state.stage, state.family),
                    state.progress,
                    state.elapsedMillis / 1_000L
                )
                primaryAction.isEnabled = false
                setupFerrofluid.setMotionState(FerrofluidView.MotionState.TRANSCRIBING)
            }
            is ModelImportCoordinator.State.Success -> {
                importProgress.visibility = View.GONE
                cancelImport.visibility = View.GONE
                setupFerrofluid.setMotionState(FerrofluidView.MotionState.SUCCESS)
                if (state.family == modelStore.selectedFamily) {
                    modelStatus.text = getString(R.string.model_ready, state.family.displayName, state.sizeMb)
                }
            }
            is ModelImportCoordinator.State.Error -> {
                importProgress.visibility = View.GONE
                cancelImport.visibility = View.GONE
                setupFerrofluid.setMotionState(FerrofluidView.MotionState.ERROR)
                modelStatus.text = importErrorMessage(state.code, state.stage)
            }
        }
    }

    private fun onImportState(state: ModelImportCoordinator.State) {
        if (state is ModelImportCoordinator.State.Success || state is ModelImportCoordinator.State.Error) renderStatus()
        else renderImportState(state)
    }

    private fun importStageLabel(
        stage: app.nuvi.android.infrastructure.model.ImportStage,
        family: ModelFamily = modelStore.selectedFamily
    ): String {
        if (stage == app.nuvi.android.infrastructure.model.ImportStage.NATIVE_PROBE) {
            return getString(R.string.model_import_testing_engine, family.displayName)
        }
        return getString(when (stage) {
        app.nuvi.android.infrastructure.model.ImportStage.PREFLIGHT -> R.string.model_import_preparing
        app.nuvi.android.infrastructure.model.ImportStage.EXTRACTING -> R.string.model_import_extracting
        app.nuvi.android.infrastructure.model.ImportStage.COPYING -> R.string.model_import_copying
        app.nuvi.android.infrastructure.model.ImportStage.STRUCTURAL_VALIDATION -> R.string.model_import_validating
        app.nuvi.android.infrastructure.model.ImportStage.NATIVE_PROBE -> R.string.model_import_testing
        app.nuvi.android.infrastructure.model.ImportStage.ACTIVATING -> R.string.model_import_activating
        app.nuvi.android.infrastructure.model.ImportStage.COMPLETE -> R.string.model_import_complete
        app.nuvi.android.infrastructure.model.ImportStage.CANCELLED -> R.string.model_import_cancelled
        app.nuvi.android.infrastructure.model.ImportStage.INTERRUPTED -> R.string.model_import_interrupted
        app.nuvi.android.infrastructure.model.ImportStage.FAILED -> R.string.model_import_failed
        })
    }

    private fun importErrorMessage(code: String, stage: app.nuvi.android.infrastructure.model.ImportStage): String = when (code) {
        "STORAGE_LOW" -> getString(R.string.model_import_error_storage)
        "MEMORY_PRESSURE" -> getString(R.string.model_import_error_memory)
        "MODEL_COPY_TIMEOUT" -> getString(R.string.model_import_error_copy_timeout)
        "MODEL_PREFLIGHT_TIMEOUT" -> getString(R.string.model_import_error_preflight_timeout)
        "FGS_TIMEOUT" -> getString(R.string.model_import_error_system_timeout)
        "MODEL_LOAD_TIMEOUT" -> getString(R.string.model_import_error_load_timeout)
        "MODEL_VALIDATION_FAILED" -> getString(R.string.model_import_error_validation_failed)
        "IMPORT_CANCELLED" -> getString(R.string.model_import_cancelled)
        "IMPORT_INTERRUPTED" -> getString(R.string.model_import_error_interrupted)
        "IMPORT_RUNNING" -> getString(R.string.model_import_running)
        else -> getString(R.string.model_import_error_invalid, importStageLabel(stage))
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, results)
        if (requestCode == MICROPHONE_REQUEST) renderStatus()
    }

    companion object { private const val MICROPHONE_REQUEST = 100; private const val MODEL_REQUEST = 101 }
}
