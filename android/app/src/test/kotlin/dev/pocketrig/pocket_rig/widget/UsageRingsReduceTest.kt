package dev.pocketrig.pocket_rig.widget

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Equivalence proof: the Kotlin reducer and the Dart one produce the same usage_rings_v1 blob from the shared fixture. */
class UsageRingsReduceTest {
    private val fixtures = File("../../test/fixtures")

    @Test
    fun matchesDartReducerOnSharedFixture() {
        val input = JSONObject(File(fixtures, "usage_rings_input.json").readText())
        val expected = JSONObject(File(fixtures, "usage_rings_expected.json").readText())
        val hosts = UsageRings.parseHosts(input.toString())
        assertTrue(hosts.isNotEmpty())
        val responses = input.getJSONObject("responses")
        val readings = hosts.map { it to (responses.getJSONObject(it.id).optJSONArray("hostUsage") ?: JSONArray()) }

        val actual = UsageRings.reduce(readings, UsageRings.parseIso("2026-11-02T00:30:00.000Z"))

        assertEquals("2026-11-02T00:30:00.000Z", actual.getString("writtenAt"))
        expected.remove("writtenAt")
        actual.remove("writtenAt")
        assertEquals(canon(expected), canon(actual))
        // The written blob must round-trip through the widget's own parser.
        assertEquals(expected.getJSONArray("rings").length(), UsageRings.parse(actual.toString()).size)
    }

    /** Plain Kotlin maps and lists so assertEquals compares structure, not org.json identity. */
    private fun canon(v: Any?): Any? = when (v) {
        is JSONObject -> v.keys().asSequence().sorted().associateWith { canon(v.get(it)) }
        is JSONArray -> (0 until v.length()).map { canon(v.get(it)) }
        is Number -> v.toDouble()
        else -> v
    }
}
