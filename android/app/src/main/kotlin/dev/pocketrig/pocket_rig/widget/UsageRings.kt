package dev.pocketrig.pocket_rig.widget

import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

private const val HOUR = 3_600_000L
private const val DAY = 24 * HOUR

/** One rate-limit window of one host+provider ring, as Flutter writes it under usage_rings_v1. */
data class Reading(
    val window: String,
    val windowSeconds: Long,
    val usedPercent: Int,
    val resetsAt: Long,
    val asOf: Long,
) {
    fun pace(now: Long): Float =
        (1f - (resetsAt - now) / (windowSeconds * 1000f)).coerceIn(0f, 1f)

    fun ahead(now: Long): Float = usedPercent / 100f - pace(now)

    /** Percent points ahead of even pace, rounded like the app's strip: used% minus round(pace%). */
    fun aheadPoints(now: Long): Int = usedPercent - Math.round(pace(now) * 100f)

    fun stale(now: Long): Boolean = now - asOf > HOUR

    val windowLabel: String get() = if (window == "weekly") "weekly" else "5h"

    /** design.md section 5, row form: "in 4h 50m", "now", or "2h ago" when stale. Rounds down. */
    fun resetShort(now: Long): String {
        if (stale(now)) {
            val age = now - asOf
            return if (age >= 2 * DAY) "${age / DAY}d ago" else "${age / HOUR}h ago"
        }
        val left = resetsAt - now
        val m = left / 60_000
        val h = left / HOUR
        val d = left / DAY
        return when {
            m < 1 -> "now"
            h < 1 -> "in ${m}m"
            d < 1 -> "in ${h}h ${"%02d".format(m % 60)}m"
            else -> "in ${d}d ${h % 24}h"
        }
    }

    /** "Resets in 4h 50m", "Resets now", or "Updated 2h ago" when stale. */
    fun resetLong(now: Long): String {
        val short = resetShort(now)
        return when {
            stale(now) -> "Updated $short"
            short == "now" -> "Resets now"
            else -> "Resets $short"
        }
    }
}

data class Ring(val hostLabel: String, val provider: String, val windows: List<Reading>) {
    fun window(name: String): Reading? = windows.firstOrNull { it.window == name }

    val providerLabel: String get() = provider.replaceFirstChar { it.uppercase() }

    fun maxAhead(now: Long): Float = windows.maxOfOrNull { it.ahead(now) } ?: Float.NEGATIVE_INFINITY
}

object UsageRings {
    const val PREFS = "HomeWidgetPreferences"
    const val KEY = "usage_rings_v1"
    val WINDOWS = listOf("five_hour", "weekly")

    /** Empty for missing or undecodable data; the widget then shows the empty state. */
    fun parse(json: String?): List<Ring> = try {
        val rings = JSONObject(json ?: return emptyList()).getJSONArray("rings")
        (0 until rings.length()).map { i ->
            val r = rings.getJSONObject(i)
            val ws = r.getJSONArray("windows")
            Ring(
                hostLabel = r.getString("hostLabel"),
                provider = r.getString("provider"),
                windows = (0 until ws.length()).map { ws.getJSONObject(it) }
                    .filter { it.getString("window") in WINDOWS }
                    .map {
                        Reading(
                            window = it.getString("window"),
                            windowSeconds = it.getLong("windowSeconds"),
                            usedPercent = it.getInt("usedPercent"),
                            resetsAt = parseIso(it.getString("resetsAt")),
                            asOf = parseIso(it.getString("asOf")),
                        )
                    },
            )
        }
    } catch (e: Exception) {
        emptyList()
    }

    /** The reading furthest ahead of its pace, shown alone by the small widget. */
    fun furthestAhead(rings: List<Ring>, now: Long): Pair<Ring, Reading>? =
        rings.flatMap { r -> r.windows.map { r to it } }.maxByOrNull { it.second.ahead(now) }

    /** Medium rows: the account most likely to hit a limit first; ties keep contract order. */
    fun sortedForRows(rings: List<Ring>, now: Long): List<Ring> = rings.sortedByDescending { it.maxAhead(now) }

    private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        .apply { timeZone = TimeZone.getTimeZone("UTC") }

    // shortcut: only UTC "Z" timestamps as in the contract, add offset parsing if a writer ever emits them.
    fun parseIso(s: String): Long {
        // Keep millis (Dart echoes them), drop anything finer, add .000 when absent.
        val t = s.replace(Regex("(\\.\\d{3})\\d*"), "$1").replace(Regex("(:\\d\\d)Z$"), "$1.000Z")
        return synchronized(iso) { iso.parse(t)!!.time }
    }

    fun formatIso(ms: Long): String = synchronized(iso) { iso.format(ms) }

    const val HOSTS_KEY = "usage_hosts_v1"
    private val WINDOW_SECONDS = mapOf("five_hour" to 18000L, "weekly" to 604800L)

    /** usage_hosts_v1: where the background worker fetches from. Empty on bad data. */
    fun parseHosts(json: String?): List<FetchHost> = try {
        val hosts = JSONObject(json ?: return emptyList()).getJSONArray("hosts")
        (0 until hosts.length()).map { hosts.getJSONObject(it) }
            .map { FetchHost(it.getString("id"), it.getString("label"), it.getString("daemonBase")) }
    } catch (e: Exception) {
        emptyList()
    }

    /**
     * Mirrors Dart usageRingsJson: the freshest reading (max asOf) per app host / daemon host /
     * provider / window, rings with no known window dropped, usedPercent rounded, first-seen order.
     * [readings] pairs each app host with its daemon's hostUsage[] (empty when the fetch failed).
     */
    fun reduce(readings: List<Pair<FetchHost, JSONArray>>, writtenAt: Long): JSONObject {
        val rings = LinkedHashMap<String, JSONObject>()
        val freshest = LinkedHashMap<String, LinkedHashMap<String, JSONObject>>()
        for ((host, usages) in readings) {
            for (i in 0 until usages.length()) {
                val u = usages.optJSONObject(i) ?: continue
                val daemonHost = u.optString("host", "local")
                val provider = u.optString("provider", "")
                val id = "${host.id}/$daemonHost/$provider"
                rings.getOrPut(id) {
                    JSONObject().put("id", id)
                        .put("hostLabel", if (daemonHost == "local") host.label else "${host.label} · $daemonHost")
                        .put("provider", provider)
                }
                val byWindow = freshest.getOrPut(id) { LinkedHashMap() }
                val ws = u.optJSONArray("windows") ?: continue
                for (j in 0 until ws.length()) {
                    val w = ws.optJSONObject(j) ?: continue
                    val window = w.opt("window") as? String ?: continue
                    val seconds = WINDOW_SECONDS[window] ?: continue
                    val used = (w.opt("usedPercent") as? Number)?.toDouble() ?: continue
                    val resetsAt = try { parseIso(w.getString("resetsAt")) } catch (e: Exception) { continue }
                    val asOf = try { parseIso(w.getString("asOf")) } catch (e: Exception) { continue }
                    val cur = byWindow[window]
                    if (cur == null || asOf > cur.getLong("asOfMs")) {
                        byWindow[window] = JSONObject()
                            .put("window", window)
                            .put("windowSeconds", seconds)
                            // One rounding here so iOS and Android show the same integer.
                            .put("usedPercent", Math.round(used).toInt())
                            .put("resetsAt", formatIso(resetsAt))
                            .put("asOf", formatIso(asOf))
                            .put("asOfMs", asOf)
                    }
                }
            }
        }
        val out = JSONArray()
        for ((id, ring) in rings) {
            val windows = freshest[id]?.values?.takeIf { it.isNotEmpty() } ?: continue
            out.put(ring.put("windows", JSONArray(windows.map { it.remove("asOfMs"); it })))
        }
        return JSONObject().put("writtenAt", formatIso(writtenAt)).put("rings", out)
    }
}

/** One app host from usage_hosts_v1; the daemon takes no token, so this carries none. */
data class FetchHost(val id: String, val label: String, val daemonBase: String)

/**
 * Green → gray → red by points ahead of pace: green at -5 or less, gray on pace, red at +5 or more, linear
 * between. Same rule and cases as Dart (test/fixtures/pace_colour.json) and Swift.
 */
object PaceColour {
    const val REACH = 5.0

    /** Stops 0 green, 1 gray, 2 red; `t` is how far from `from` to `to`. */
    data class Segment(val from: Int, val to: Int, val t: Double)

    fun segment(ahead: Int): Segment = when {
        ahead <= -REACH -> Segment(0, 0, 0.0)
        ahead >= REACH -> Segment(2, 2, 0.0)
        ahead < 0 -> Segment(0, 1, (ahead + REACH) / REACH)
        else -> Segment(1, 2, ahead / REACH)
    }

    /** 0xAARRGGBB for [ahead] from the three stops. */
    fun argb(ahead: Int, green: Long, gray: Long, red: Long): Long {
        val stops = longArrayOf(green, gray, red)
        val s = segment(ahead)
        fun channel(shift: Int): Long {
            val a = ((stops[s.from] shr shift) and 0xFF).toDouble()
            val b = ((stops[s.to] shr shift) and 0xFF).toDouble()
            return Math.round(a + (b - a) * s.t) shl shift
        }
        return 0xFF000000 or channel(16) or channel(8) or channel(0)
    }
}
