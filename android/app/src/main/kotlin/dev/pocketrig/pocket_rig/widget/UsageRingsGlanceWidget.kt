package dev.pocketrig.pocket_rig.widget

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.util.TypedValue
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import dev.pocketrig.pocket_rig.MainActivity

/** Pace bars, matching the app's usage strip and the iOS widget. */
class UsageRingsGlanceWidget : GlanceAppWidget() {
    // Exact so the label truncation, bar widths and the small/medium choice see the real cell size.
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val json = context.getSharedPreferences(UsageRings.PREFS, Context.MODE_PRIVATE)
            .getString(UsageRings.KEY, null)
        val rings = UsageRings.parse(json)
        provideContent { Content(context, rings) }
    }
}

private const val PAD = 14
/** Ahead of pace by more than 2 points reads as ahead; within it, on pace (same as the app strip). */
private const val SLACK = 0.02f

/** Picked once per render from the system night mode. */
private class Palette(private val dark: Boolean) {
    val background = if (dark) 0xFF1C1C1E else 0xFFFFFFFF
    val track = if (dark) 0xFF3A3A3A else 0xFFD9D9D9
    val green = if (dark) 0xFF3FB950 else 0xFF1A7F37
    val red = if (dark) 0xFFF85149 else 0xFFCF222E
    val faint = if (dark) 0xFF6E6E6E else 0xFF9E9E9E
    val ink = if (dark) 0xFFEDEDED else 0xFF1A1A1A
    val muted = if (dark) 0xFFA6A6A6 else 0xFF616161

    /** The percent text: the pace gradient (the app's added / muted / removed stops), plain ink when stale. */
    fun pace(r: Reading, now: Long): Long =
        if (r.stale(now)) ink else if (dark) PaceColour.argb(r.aheadPoints(now), 0xFFA1C181, 0xFFA6A6A6, 0xFFD07277)
        else PaceColour.argb(r.aheadPoints(now), 0xFF34804A, 0xFF616161, 0xFFC2475A)

    fun fill(r: Reading?, now: Long): Long = when {
        r == null || r.stale(now) -> faint
        r.ahead(now) > SLACK -> red
        else -> green
    }
}

private fun Long.provider() = ColorProvider(Color(this))

private fun style(colour: Long, size: Int, weight: FontWeight = FontWeight.Normal, align: TextAlign = TextAlign.Start) =
    TextStyle(color = colour.provider(), fontSize = size.sp, fontWeight = weight, textAlign = align)

private fun label(window: String) = if (window == "weekly") "week" else "5h"

private fun aheadPoints(r: Reading, now: Long) = Math.round(r.ahead(now) * 100)

/** "week 11% ahead · in 2d 19h", "on pace", or "Updated 3h ago" when every window is stale. */
private fun head(ring: Ring, now: Long, p: Palette): Pair<String, Long> {
    val w = ring.windows.filter { !it.stale(now) }.maxByOrNull { it.ahead(now) }
        ?: return (ring.windows.firstOrNull()?.resetLong(now) ?: "no data") to p.faint
    return if (w.ahead(now) > SLACK) "${label(w.window)} ${aheadPoints(w, now)}% ahead · ${w.resetShort(now)}" to p.red
    else "on pace" to p.green
}

@Composable
private fun Content(context: Context, rings: List<Ring>) {
    val now = System.currentTimeMillis()
    val p = Palette(context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES)
    val size = LocalSize.current
    val medium = size.width > size.height * 1.5f
    val top = UsageRings.furthestAhead(rings, now)
    val inner = size.width.value - 2 * PAD
    Box(
        modifier = GlanceModifier.fillMaxSize()
            .background(p.background.provider())
            .cornerRadius(16.dp)
            .padding(PAD.dp)
            .clickable(actionStartActivity<MainActivity>()),
        contentAlignment = if (top == null) Alignment.Center else Alignment.TopStart,
    ) {
        when {
            top == null -> Empty(context, p, now, inner)
            !medium -> Small(context, p, top.first, top.second, now, inner)
            else -> MediumRows(context, p, rings, now, inner)
        }
    }
}

@Composable
private fun Empty(context: Context, p: Palette, now: Long, widthDp: Float) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        UsageRings.WINDOWS.forEach { w ->
            BarRow(context, p, w, null, now, widthDp, 8, number = false)
            Spacer(GlanceModifier.height(8.dp))
        }
        Spacer(GlanceModifier.height(4.dp))
        Text("Open Pocket Rig to connect a host", maxLines = 2, style = style(p.muted, 11, align = TextAlign.Center))
    }
}

@Composable
private fun Small(context: Context, p: Palette, ring: Ring, r: Reading, now: Long, widthDp: Float) {
    val colour = p.fill(r, now)
    val status = when {
        r.stale(now) -> r.resetLong(now)
        r.ahead(now) > SLACK -> "${aheadPoints(r, now)}% ahead · ${r.resetShort(now)}"
        else -> "on pace · ${r.resetShort(now)}"
    }
    Column(modifier = GlanceModifier.fillMaxSize()) {
        Text(
            fitLabel(context, ring.hostLabel, " · ${ring.providerLabel}", widthDp, dropSuffix = true),
            maxLines = 1,
            style = style(p.ink, 11, FontWeight.Bold),
        )
        Spacer(GlanceModifier.height(2.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text("${r.usedPercent}%", style = style(if (r.stale(now)) colour else p.pace(r, now), 34, FontWeight.Bold))
            Spacer(GlanceModifier.width(6.dp))
            Text(label(r.window), modifier = GlanceModifier.padding(bottom = 6.dp), style = style(p.muted, 12, FontWeight.Medium))
        }
        Text(status, maxLines = 1, style = style(colour, 11, FontWeight.Bold))
        Spacer(GlanceModifier.defaultWeight())
        UsageRings.WINDOWS.forEachIndexed { i, w ->
            if (i > 0) Spacer(GlanceModifier.height(8.dp))
            BarRow(context, p, w, ring.window(w), now, widthDp, 6, number = false)
        }
    }
}

@Composable
private fun MediumRows(context: Context, p: Palette, rings: List<Ring>, now: Long, widthDp: Float) {
    val sorted = UsageRings.sortedForRows(rings, now)
    val half = (widthDp - 16) / 2
    Column(modifier = GlanceModifier.fillMaxSize()) {
        sorted.take(2).forEachIndexed { i, ring ->
            if (i > 0) Spacer(GlanceModifier.height(12.dp))
            val (text, colour) = head(ring, now, p)
            Row(modifier = GlanceModifier.fillMaxWidth()) {
                Text(
                    fitLabel(context, ring.hostLabel, " · ${ring.providerLabel}", widthDp * 0.5f, dropSuffix = false),
                    modifier = GlanceModifier.defaultWeight(),
                    maxLines = 1,
                    style = style(p.ink, 11, FontWeight.Bold),
                )
                Text(text, maxLines = 1, style = style(colour, 11, FontWeight.Bold))
            }
            Spacer(GlanceModifier.height(6.dp))
            Row(modifier = GlanceModifier.fillMaxWidth()) {
                UsageRings.WINDOWS.forEachIndexed { j, w ->
                    if (j > 0) Spacer(GlanceModifier.width(16.dp))
                    BarRow(context, p, w, ring.window(w), now, half, 8, number = true)
                }
            }
        }
        Spacer(GlanceModifier.defaultWeight())
        Text(
            if (sorted.size > 2) "+${sorted.size - 2} more in the app" else "| where even use would be now",
            modifier = GlanceModifier.fillMaxWidth(),
            style = style(p.muted, 10, align = if (sorted.size > 2) TextAlign.End else TextAlign.Start),
        )
    }
}

/** `5h [bar] 62%` in [widthDp]; the bar takes what the label and number leave. */
@Composable
private fun BarRow(context: Context, p: Palette, window: String, r: Reading?, now: Long, widthDp: Float, barDp: Int, number: Boolean) {
    val barWidth = (widthDp - 36 - if (number) 40 else 0).coerceAtLeast(20f)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label(window), modifier = GlanceModifier.width(30.dp), style = style(p.muted, 11))
        Spacer(GlanceModifier.width(6.dp))
        Image(
            provider = ImageProvider(barBitmap(context, barWidth, barDp, r, now, p)),
            contentDescription = r?.let { "${label(window)} ${it.usedPercent}% used, ${it.resetLong(now)}" } ?: "${label(window)} no data",
            modifier = GlanceModifier.width(barWidth.dp).height((barDp + 6).dp),
        )
        if (number) {
            Text(
                r?.let { "${it.usedPercent}%" } ?: "—",
                modifier = GlanceModifier.width(40.dp),
                style = style(if (r == null) p.faint else p.pace(r, now), 12, FontWeight.Bold, TextAlign.End),
            )
        }
    }
}

/** design.md section 4: keep provider and window, drop the " · daemonHost" suffix first, then tail-truncate the host. */
private fun fitLabel(context: Context, host: String, tail: String, widthDp: Float, dropSuffix: Boolean): String {
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 11f, context.resources.displayMetrics)
        // Labels render Bold; measuring bold never under-truncates.
        typeface = Typeface.DEFAULT_BOLD
    }
    val maxPx = widthDp * context.resources.displayMetrics.density
    fun fits(h: String) = paint.measureText(h + tail) <= maxPx
    if (fits(host)) return host + tail
    var h = if (dropSuffix) host.substringBefore(" · ") else host
    if (fits(h)) return h + tail
    while (h.length > 1 && !fits("$h…")) h = h.dropLast(1).trimEnd()
    return "$h…$tail"
}

/** Track, used fill, and a tick 6 dp taller than the bar where even use would be now. */
private fun barBitmap(context: Context, widthDp: Float, barDp: Int, r: Reading?, now: Long, p: Palette): Bitmap {
    val d = context.resources.displayMetrics.density
    val w = (widthDp * d).toInt().coerceAtLeast(1)
    val h = ((barDp + 6) * d).toInt()
    val bar = barDp * d
    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bmp)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    val top = (h - bar) / 2
    paint.color = p.track.toInt()
    canvas.drawRoundRect(RectF(0f, top, w.toFloat(), top + bar), bar / 2, bar / 2, paint)
    if (r == null) return bmp
    val used = w * r.usedPercent.coerceIn(0, 100) / 100f
    if (used > 0) {
        paint.color = p.fill(r, now).toInt()
        canvas.drawRoundRect(RectF(0f, top, used.coerceAtLeast(bar), top + bar), bar / 2, bar / 2, paint)
    }
    val x = (w * r.pace(now)).coerceIn(d, w - d)
    paint.color = (if (r.stale(now)) p.faint else p.ink).toInt()
    canvas.drawRoundRect(RectF(x - d, 0f, x + d, h.toFloat()), d, d, paint)
    return bmp
}
