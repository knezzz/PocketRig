package dev.pocketrig.pocket_rig

import android.appwidget.AppWidgetManager
import android.content.Context
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import dev.pocketrig.pocket_rig.widget.UsageFetchWorker
import dev.pocketrig.pocket_rig.widget.UsageRingsGlanceWidget

/** Lives at the application-id root because home_widget resolves androidName "UsageRingsWidget" against it. */
class UsageRingsWidget : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = UsageRingsGlanceWidget()

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        UsageFetchWorker.enqueue(context)
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        super.onUpdate(context, appWidgetManager, appWidgetIds)
        UsageFetchWorker.enqueue(context)
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        UsageFetchWorker.cancel(context)
    }
}
