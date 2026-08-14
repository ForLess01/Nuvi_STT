package app.nuvi.android.presentation

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import app.nuvi.android.R

internal fun Context.dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

internal fun Context.roundedSurface(radiusDp: Int = 24): GradientDrawable = GradientDrawable().apply {
    cornerRadius = dp(radiusDp).toFloat()
    setColor(getColor(R.color.surface_container))
    setStroke(dp(1), getColor(R.color.divider))
}

internal fun Context.opticalGlassDrawable(): GradientDrawable {
    val reduced = getSharedPreferences("appearance", Context.MODE_PRIVATE).getBoolean("reduced-transparency", false)
    return GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(
        if (reduced) getColor(R.color.surface_container) else getColor(R.color.glass_stroke),
        if (reduced) getColor(R.color.surface_container) else getColor(R.color.glass_fill)
    )).apply {
        cornerRadius = dp(28).toFloat()
        setStroke(dp(1), getColor(R.color.glass_stroke))
    }
}

internal fun Context.textLabel(value: String, size: Float, bold: Boolean = false): TextView = TextView(this).apply {
    text = value
    textSize = size
    setTextColor(getColor(R.color.content_primary))
    if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
}

internal fun Context.badge(value: String): TextView = textLabel(value, 12f, true).apply {
    gravity = Gravity.CENTER
    setTextColor(getColor(R.color.accent))
    background = GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(getColor(R.color.accent_soft)) }
    setPadding(dp(10), dp(4), dp(10), dp(4))
}

internal fun Context.primaryButton(label: String, action: () -> Unit): Button = Button(this).apply {
    text = label
    isAllCaps = false
    textSize = 15f
    minHeight = dp(48)
    setTextColor(Color.WHITE)
    backgroundTintList = android.content.res.ColorStateList.valueOf(getColor(R.color.accent))
    setOnClickListener { action() }
}

internal fun View.withMargins(left: Int = 0, top: Int = 0, right: Int = 0, bottom: Int = 0): LinearLayout.LayoutParams =
    LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
        setMargins(context.dp(left), context.dp(top), context.dp(right), context.dp(bottom))
    }
