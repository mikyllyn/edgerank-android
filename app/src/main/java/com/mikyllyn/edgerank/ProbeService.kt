package com.mikyllyn.edgerank

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service that keeps the probing job alive while the screen is off /
 * the app is backgrounded. Without it Android throttles background network and
 * every probe fails (empty results after unlock).
 */
class ProbeService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notif = buildNotification()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID, notif)
        }
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        val chId = "edgerank_probe"
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(chId, "Замер CDN эджей", NotificationManager.IMPORTANCE_LOW)
            ch.setShowBadge(false)
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
        )
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, chId)
        else Notification.Builder(this)
        return b.setContentTitle("EdgeRank: идёт замер")
            .setContentText("Тестирование CDN эджей — можно заблокировать экран")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val NOTIF_ID = 42

        fun start(ctx: Context) {
            val i = Intent(ctx, ProbeService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (e: Exception) { /* background-start restricted; scan still runs */ }
        }

        fun stop(ctx: Context) {
            try { ctx.stopService(Intent(ctx, ProbeService::class.java)) } catch (e: Exception) {}
        }
    }
}
