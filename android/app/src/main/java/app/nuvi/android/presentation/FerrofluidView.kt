package app.nuvi.android.presentation

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RuntimeShader
import android.content.res.Configuration
import android.os.Build
import android.os.PowerManager
import android.util.AttributeSet
import android.view.View
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

class FerrofluidView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : View(context, attrs) {
    enum class MotionState { IDLE, RECORDING, TRANSCRIBING, SUCCESS, ERROR, LOCKED }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val fallbackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = context.getColor(app.nuvi.android.R.color.accent)
        maskFilter = BlurMaskFilter(2.5f * resources.displayMetrics.density, BlurMaskFilter.Blur.NORMAL)
    }
    private val corePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = context.getColor(app.nuvi.android.R.color.accent)
        style = Paint.Style.FILL
    }
    private val chamberPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(246, 246, 246)
        style = Paint.Style.FILL
    }
    private val powerManager = context.getSystemService(PowerManager::class.java)
    private val appearancePreferences = context.getSharedPreferences("appearance", Context.MODE_PRIVATE)
    private val preferenceListener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == "reduced-transparency") refreshRenderingPolicy()
    }
    private val shader = if (Build.VERSION.SDK_INT >= 33) RuntimeShader(AGSL) else null
    private var motionState = MotionState.IDLE
    private var targetLevel = 0f
    private var level = 0f
    private val renderStarted = android.os.SystemClock.uptimeMillis()
    private var stateStarted = 0L
    private var running = false
    private var animationsAllowed = false
    private var transparencyReduced = false

    fun setMotionState(value: MotionState) {
        if (motionState == value) return
        motionState = value
        stateStarted = android.os.SystemClock.uptimeMillis()
        updateRendering()
        invalidate()
    }

    /** Accepts normalized RMS only; raw microphone samples never enter the view. */
    fun setNormalizedLevel(value: Float) {
        targetLevel = value.coerceIn(0f, 1f)
        if (motionState == MotionState.RECORDING && running) invalidate()
    }

    fun refreshRenderingPolicy() {
        transparencyReduced = appearancePreferences.getBoolean("reduced-transparency", false) ||
            runCatching { android.provider.Settings.Secure.getInt(context.contentResolver, "high_text_contrast_enabled", 0) }
                .getOrDefault(0) == 1
        animationsAllowed = ValueAnimator.areAnimatorsEnabled() && powerManager?.isPowerSaveMode != true
        updateRendering()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val now = android.os.SystemClock.uptimeMillis()
        val stateElapsed = (now - stateStarted) / 1000f
        val renderElapsed = (now - renderStarted) / 1000f
        // Match the desktop Metal renderer: the fluid eases symmetrically toward
        // microphone energy instead of snapping open and collapsing slowly.
        level += (targetLevel - level) * 0.22f
        if (shader != null) drawShader(canvas, renderElapsed) else drawFallback(canvas, renderElapsed)
        if (running) postInvalidateDelayed(33L)
        if ((motionState == MotionState.SUCCESS && stateElapsed > .22f) || (motionState == MotionState.ERROR && stateElapsed > .36f)) {
            setMotionState(MotionState.IDLE)
        }
    }

    @android.annotation.TargetApi(33)
    private fun drawShader(canvas: Canvas, elapsed: Float) {
        val stateValue = when (motionState) {
            MotionState.IDLE -> 0f; MotionState.RECORDING -> 1f; MotionState.TRANSCRIBING -> 2f
            MotionState.SUCCESS -> 3f; MotionState.ERROR -> 4f; MotionState.LOCKED -> 5f
        }
        shader!!.setFloatUniform("resolution", width.toFloat(), height.toFloat())
        shader.setFloatUniform("time", elapsed)
        shader.setFloatUniform("level", level)
        shader.setFloatUniform("state", stateValue)
        shader.setFloatUniform("dark", if (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES) 1f else 0f)
        paint.shader = shader
        val radius = min(width, height) * .5f
        canvas.drawCircle(width * .5f, height * .5f, radius, paint)
    }

    private fun drawFallback(canvas: Canvas, elapsed: Float) {
        val centerX = width / 2f
        val centerY = height / 2f
        val extent = min(width, height).toFloat()
        val activeLevel = if (motionState == MotionState.TRANSCRIBING) {
            .45f + .45f * (.5f + .5f * sin(elapsed * 3.1f))
        } else level
        val base = extent * (.235f + activeLevel * .045f)
        val orbit = extent * (.085f + activeLevel * .12f)
        val speed = 1.1f
        canvas.drawCircle(centerX, centerY, extent * .5f, chamberPaint)
        fallbackPaint.color = when (motionState) {
            MotionState.ERROR -> Color.rgb(77, 18, 24)
            MotionState.SUCCESS -> Color.rgb(16, 67, 46)
            MotionState.LOCKED -> Color.rgb(72, 79, 94)
            else -> Color.rgb(3, 3, 3)
        }
        corePaint.color = fallbackPaint.color
        canvas.drawCircle(centerX, centerY, base, fallbackPaint)
        canvas.drawCircle(centerX, centerY, base * .88f, corePaint)
        repeat(7) { index ->
            val fi = index + 1f
            val angle = fi * 2.399963f + elapsed * (speed * (.24f + index * .01f))
            val distance = orbit * (.72f + (index % 3) * .13f)
            val radius = base * (.27f + (index % 4) * .07f)
            canvas.drawCircle(centerX + cos(angle) * distance, centerY + sin(angle) * distance, radius * 1.10f, fallbackPaint)
            canvas.drawCircle(centerX + cos(angle) * distance, centerY + sin(angle) * distance, radius, corePaint)
        }
    }

    private fun updateRendering() {
        running = isAttachedToWindow && isShown && animationsAllowed && !transparencyReduced &&
            motionState in setOf(MotionState.RECORDING, MotionState.TRANSCRIBING, MotionState.SUCCESS, MotionState.ERROR)
    }

    override fun onAttachedToWindow() { super.onAttachedToWindow(); appearancePreferences.registerOnSharedPreferenceChangeListener(preferenceListener); refreshRenderingPolicy() }
    override fun onDetachedFromWindow() { running = false; appearancePreferences.unregisterOnSharedPreferenceChangeListener(preferenceListener); super.onDetachedFromWindow() }
    override fun onVisibilityChanged(changedView: View, visibility: Int) { super.onVisibilityChanged(changedView, visibility); if (visibility == VISIBLE) refreshRenderingPolicy() else updateRendering() }

    companion object {
        private const val AGSL = """
            uniform float2 resolution;
            uniform float time;
            uniform float level;
            uniform float state;
            uniform float dark;

            float hash21(float2 p) {
                p = fract(p * float2(123.34, 345.45));
                p += dot(p, p + 34.345);
                return fract(p.x * p.y);
            }

            float vnoise(float2 p) {
                float2 i = floor(p);
                float2 f = fract(p);
                float a = hash21(i);
                float b = hash21(i + float2(1.0, 0.0));
                float c = hash21(i + float2(0.0, 1.0));
                float d = hash21(i + float2(1.0, 1.0));
                float2 u = f * f * (3.0 - 2.0 * f);
                return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
            }

            float fbm(float2 p) {
                float value = 0.0;
                float amplitude = 0.5;
                for (int i = 0; i < 5; i++) {
                    value += amplitude * vnoise(p);
                    p = p * 2.03 + float2(7.13, -3.71);
                    amplitude *= 0.5;
                }
                return value;
            }

            float organicLobes(float2 sample, float2 center, float radius,
                               float energy, float lobes, float index, float t) {
                float2 delta = sample - center;
                float distance = length(delta);
                if (distance > radius * 3.2) { return 0.0; }
                float angle = atan(delta.y, delta.x);
                float wave = sin(angle * lobes + t * (1.7 + index * 0.13));
                float detail = fbm(delta * (5.4 + index * 0.37) + float2(t * 0.22, -t * 0.18));
                float rounded = pow(abs(wave) * 0.72 + detail * 0.35, 1.392);
                return (rounded - 0.28) * energy * radius * 0.56;
            }

            float stretchedMetaball(float2 sample, float2 center, float radius,
                                    float2 velocityAxis, float stretch) {
                float2 delta = sample - center;
                float velocity = length(velocityAxis);
                if (velocity > 0.0001) {
                    float2 axis = velocityAxis / velocity;
                    float2 normal = float2(-axis.y, axis.x);
                    float along = dot(delta, axis);
                    float across = dot(delta, normal);
                    delta = axis * (along / stretch) + normal * (across * stretch);
                }
                float dd = dot(delta, delta) + 0.00008;
                return pow((radius * radius) / dd, 1.18);
            }

            float chamberField(float2 uv, float activeLevel) {
                float t = time;
                float lvl = clamp(activeLevel, 0.0, 1.0);
                float breath = 0.5 + 0.5 * sin(t * 1.65);
                float energy = smoothstep(0.02, 0.72, lvl);
                float2 warp = float2(
                    fbm(uv * 2.05 + float2(0.0, t * 0.28)),
                    fbm(uv * 2.05 + float2(4.7, -t * 0.24))
                ) - 0.5;
                float2 sample = uv + warp * (0.035 + 0.095 * energy);

                float coreSize = 0.31;
                float reach = 0.68;
                float coreRadius = coreSize * (1.08 + 0.22 * energy) + 0.011 * breath;
                float coreLobe = organicLobes(sample, float2(0.0, -0.045), coreRadius,
                    0.18 + energy * 0.28, 3.0, 0.0, t);
                float field = stretchedMetaball(sample, float2(0.0, -0.045), coreRadius + coreLobe,
                    float2(0.03 * sin(t), 0.02 * cos(t * 0.8)), 1.0 + energy * 0.10);

                for (int i = 1; i < 8; i++) {
                    float fi = float(i);
                    float seed = hash21(float2(fi, 9.17));
                    float baseAngle = fi * 2.399963 + seed * 0.9;
                    float orbit = t * (0.24 + 0.08 * seed) + sin(t * 0.41 + fi) * 0.22;
                    float angle = baseAngle + orbit;
                    float band = 0.52 + 0.48 * sin(t * (1.1 + seed * 1.6) + fi * 1.37);
                    band = smoothstep(0.12, 1.0, band * energy + lvl * (0.45 + seed * 0.25));
                    float restDistance = coreSize * (0.36 + 0.12 * seed);
                    float pushedDistance = coreSize * (0.68 + seed * 0.35) + reach * band * 0.31;
                    float cohesion = 1.0 - exp(-2.8 * energy);
                    float distance = mix(restDistance, pushedDistance, cohesion);
                    float2 radial = float2(cos(angle), sin(angle));
                    float2 tangent = float2(-radial.y, radial.x);
                    float2 center = float2(0.0, -0.045) + radial * distance + tangent * (0.018 * sin(t * 1.4 + fi));
                    float baseRadius = coreSize * mix(0.27, 0.58, hash21(float2(fi, 2.4)));
                    baseRadius *= 1.0 + band * 0.24;
                    float lobes = mix(2.0, 6.0, hash21(float2(fi, 5.8)));
                    float lobeOffset = organicLobes(sample, center, baseRadius, band, lobes, fi, t);
                    float2 velocityAxis = normalize(radial * (0.55 + band) + tangent * (0.28 + seed * 0.34));
                    float stretch = clamp(1.0 + band * (0.32 + reach * 0.32), 1.0, 1.95);
                    field += stretchedMetaball(sample, center, baseRadius + lobeOffset, velocityAxis, stretch);
                }

                float bridgeNoise = fbm(sample * 6.34 + float2(t * 0.35, -t * 0.31));
                float ridge = 1.0 - abs(2.0 * bridgeNoise - 1.0);
                field += pow(clamp(ridge, 0.0, 1.0), 2.2) * clamp(field, 0.0, 1.0) * energy * 0.34;
                return field;
            }

            half4 main(float2 p) {
                float2 uv = (p - resolution * 0.5) / (min(resolution.x, resolution.y) * 0.5);
                float distanceFromCenter = length(uv);
                float disk = smoothstep(1.0, 0.972, distanceFromCenter);
                if (disk <= 0.001) { return half4(0.0); }

                float activeLevel = state == 2.0
                    ? 0.45 + 0.45 * (0.5 + 0.5 * sin(time * 3.1))
                    : level;
                float field = chamberField(uv, activeLevel);
                float edgeWidth = 0.0762;
                float ink = smoothstep(1.05 - edgeWidth, 1.05 + edgeWidth, field);
                ink *= smoothstep(0.97, 0.76, distanceFromCenter);

                float3 background = float3(0.965);
                float3 fluid = state == 4.0 ? float3(0.30, 0.055, 0.075)
                    : (state == 3.0 ? float3(0.035, 0.24, 0.14)
                    : (state == 5.0 ? float3(0.28, 0.31, 0.38) : float3(0.010, 0.011, 0.012)));
                float contact = smoothstep(0.20, 1.08, field) * (1.0 - ink);
                float vignette = smoothstep(1.0, 0.15, distanceFromCenter);
                float3 chamber = background - vignette * 0.045 - contact * 0.20;

                float2 eps = float2(0.010, 0.0);
                float fx = chamberField(uv + eps.xy, activeLevel) - chamberField(uv - eps.xy, activeLevel);
                float fy = chamberField(uv + eps.yx, activeLevel) - chamberField(uv - eps.yx, activeLevel);
                float3 normal = normalize(float3(fx, fy, 0.42));
                float3 lightA = normalize(float3(-0.45, -0.62, 1.0));
                float3 lightB = normalize(float3(0.72, 0.34, 0.85));
                float diffuse = max(dot(normal, lightA), 0.0) * 0.38 + max(dot(normal, lightB), 0.0) * 0.16;
                float3 viewDirection = float3(0.0, 0.0, 1.0);
                float specA = pow(max(dot(reflect(-lightA, normal), viewDirection), 0.0), 42.0);
                float specB = pow(max(dot(reflect(-lightB, normal), viewDirection), 0.0), 24.0) * 0.24;
                float rim = smoothstep(1.10, 1.45, field) * (1.0 - smoothstep(1.48, 2.3, field));
                float3 wetFluid = fluid + diffuse * 0.16;
                float3 specTint = mix(float3(0.95, 0.97, 1.0), normalize(fluid + 0.001), 0.35);
                wetFluid += (specA + specB) * specTint;
                wetFluid += rim * (fluid * 0.35 + 0.03) * (0.6 + activeLevel);
                float3 color = mix(chamber, wetFluid, ink);

                float rimShade = smoothstep(0.78, 1.0, distanceFromCenter);
                color -= rimShade * 0.11;
                color += smoothstep(0.22, 0.0, length(uv - float2(-0.32, -0.42))) * 0.043;
                return half4(half3(clamp(color, 0.0, 1.0)), half(disk));
            }
        """
    }
}
