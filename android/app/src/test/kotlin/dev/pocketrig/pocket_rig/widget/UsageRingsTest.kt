package dev.pocketrig.pocket_rig.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UsageRingsTest {
    private val fixture = """
        {"writtenAt":"2026-11-02T00:20:34.709Z","rings":[{"id":"a/local/claude","hostLabel":"Macmini","provider":"claude","windows":[
          {"window":"five_hour","windowSeconds":18000,"usedPercent":4,"resetsAt":"2026-11-02T05:10:00.000Z","asOf":"2026-11-02T00:20:34.709Z"},
          {"window":"weekly","windowSeconds":604800,"usedPercent":57,"resetsAt":"2026-11-04T00:00:00.000Z","asOf":"2026-11-02T00:19:45.974Z"},
          {"window":"daily","windowSeconds":1,"usedPercent":0,"resetsAt":"2026-11-02T00:00:00Z","asOf":"2026-11-02T00:00:00Z"}]}]}
    """

    @Test
    fun parsesContractAndDerivesAtRenderTime() {
        val rings = UsageRings.parse(fixture)
        val now = UsageRings.parseIso("2026-11-02T01:20:00Z")
        val five = rings.single().window("five_hour")!!
        val weekly = rings.single().window("weekly")!!
        assertEquals(2, rings.single().windows.size) // unknown "daily" window ignored

        // 5h window ends 05:10 so started 00:10; at 01:20, 70 of 300 minutes elapsed.
        assertEquals(70f / 300f, five.pace(now), 0.001f)
        assertTrue(five.ahead(now) < 0) // 4% used, below pace: green
        assertTrue(Reading("five_hour", 18000, 90, five.resetsAt, five.asOf).ahead(now) > 0) // red

        // asOf 00:20:34 is 59m26s old, 00:19:45 is 60m15s old.
        assertFalse(five.stale(now))
        assertTrue(weekly.stale(now))

        // five: 0.04 - 0.233 = -0.193; weekly: 0.57 - 0.726 = -0.156; weekly is furthest ahead.
        assertEquals(weekly, UsageRings.furthestAhead(rings, now)!!.second)

        // design.md section 5
        assertEquals("Resets in 3h 50m", five.resetLong(now))
        assertEquals("Updated 1h ago", weekly.resetLong(now))
        assertEquals("in 2d 4h", five.copy(resetsAt = now + (52 * 60 + 7) * 60_000L).resetShort(now))
        assertEquals("Resets now", five.copy(resetsAt = now - 1).resetLong(now))
        assertEquals("Claude", rings.single().providerLabel)
    }

    @Test
    fun badDataIsEmpty() {
        assertTrue(UsageRings.parse(null).isEmpty())
        assertTrue(UsageRings.parse("{nope").isEmpty())
        assertTrue(UsageRings.parse("""{"rings":[{"hostLabel":"x"}]}""").isEmpty())
    }

    @Test
    fun paceColourMatchesTheSharedCases() {
        // Run from android/app by Gradle; the cases live with the Dart test.
        val cases = org.json.JSONObject(java.io.File("../../test/fixtures/pace_colour.json").readText()).getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val s = PaceColour.segment(c.getInt("ahead"))
            assertEquals("ahead ${c.getInt("ahead")}", c.getInt("from"), s.from)
            assertEquals("ahead ${c.getInt("ahead")}", c.getInt("to"), s.to)
            assertEquals("ahead ${c.getInt("ahead")}", c.getDouble("t"), s.t, 1e-9)
        }
        val g = 0xFF34804AL; val a = 0xFF616161L; val r = 0xFFC2475AL
        assertEquals(g, PaceColour.argb(-20, g, a, r))
        assertEquals(a, PaceColour.argb(0, g, a, r))
        assertEquals(r, PaceColour.argb(20, g, a, r))
    }
}
