package dev.pocketrig.pocket_rig.widget

import android.content.Context
import androidx.glance.appwidget.updateAll
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * SPEC requirement 7: with the app closed, fetch every host's /api/provider/status about every
 * 15 minutes and write usage_rings_v1 exactly as Flutter would. A host that fails is skipped;
 * when every host fails the stored blob is left alone and the stale rule greys it.
 */
class UsageFetchWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences(UsageRings.PREFS, Context.MODE_PRIVATE)
        val hosts = UsageRings.parseHosts(prefs.getString(UsageRings.HOSTS_KEY, null))
        if (hosts.isEmpty()) return Result.success()
        val fetched = withContext(Dispatchers.IO) {
            coroutineScope { hosts.map { async { fetch(it) } }.awaitAll() }
        }
        // success, not retry: retry() puts the period on exponential backoff (up to 5 h), so an
        // hour off Tailscale would lag refreshes for hours; the next 15-min period tries again.
        if (fetched.all { it == null }) return Result.success()
        val readings = hosts.zip(fetched) { h, rows -> h to (rows ?: JSONArray()) }
        val json = UsageRings.reduce(readings, System.currentTimeMillis()).toString()
        prefs.edit().putString(UsageRings.KEY, json).commit()
        UsageRingsGlanceWidget().updateAll(applicationContext)
        return Result.success()
    }

    /** The daemon's hostUsage[] or null when the host did not answer in time. */
    private fun fetch(host: FetchHost): JSONArray? = try {
        val conn = URL("${host.daemonBase.trimEnd('/')}/api/provider/status").openConnection() as HttpURLConnection
        conn.connectTimeout = TIMEOUT_MS
        conn.readTimeout = TIMEOUT_MS
        try {
            if (conn.responseCode >= 400) null
            else JSONObject(conn.inputStream.bufferedReader().readText()).optJSONArray("hostUsage") ?: JSONArray()
        } finally {
            conn.disconnect()
        }
    } catch (e: Exception) {
        null
    }

    companion object {
        private const val NAME = "usage_rings_fetch"
        private const val TIMEOUT_MS = 8_000

        /** Idempotent: KEEP leaves an already scheduled request in place. */
        fun enqueue(context: Context) {
            val request = PeriodicWorkRequestBuilder<UsageFetchWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(NAME)
        }
    }
}
