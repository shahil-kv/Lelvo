package app.lelvo.android.background

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.Build
import android.os.PowerManager

/**
 * What Android will actually allow this app to do in the background. Read-only: the Backup tab's Fix
 * button opens a settings screen, it never asks for the restricted battery permission.
 */
object DeviceState {
    fun ignoringBatteryOptimizations(context: Context): Boolean =
        (context.getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(context.packageName)

    fun backgroundRestricted(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= 28)
            (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).isBackgroundRestricted
        else false

    /** The app's own standby bucket. No permission is required to read it. */
    fun standbyBucket(context: Context): Int =
        if (Build.VERSION.SDK_INT >= 28)
            (context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager).appStandbyBucket
        else -1

    /** True when the last process exit was a force stop. Android 10 has no history; assume it was not. */
    fun lastExitWasForceStop(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 30) return false
        val reasons = (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
            .getHistoricalProcessExitReasons(context.packageName, 0, 1)
        return reasons.firstOrNull()?.reason == ApplicationExitInfo.REASON_USER_REQUESTED
    }
}
