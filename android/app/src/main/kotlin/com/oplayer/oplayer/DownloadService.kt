package com.oplayer.oplayer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodChannel

class DownloadService : Service() {
    companion object {
        const val OPEN = "oplayer_open_downloads"
        private const val CHANNEL = "oplayer_downloads"
        private const val FOREGROUND_ID = 7920
        private const val PAUSE = "com.oplayer.oplayer.DOWNLOAD_PAUSE"
        var events: MethodChannel? = null
        var pendingStart: MethodChannel.Result? = null
        var running = false
        var openPending = false

        fun completed(context: android.content.Context, id: String, name: String, success: Boolean) {
            ensureChannel(context)
            val notification = builder(context)
                .setContentTitle(if (success) "다운로드 완료" else "다운로드 실패")
                .setContentText(name)
                .setAutoCancel(true)
                .setContentIntent(openIntent(context))
                .build()
            val notificationId = 100000 + (id.hashCode() and 0x0fffffff)
            context.getSystemService(NotificationManager::class.java).notify(notificationId, notification)
        }

        private fun ensureChannel(context: android.content.Context) {
            if (Build.VERSION.SDK_INT >= 26) context.getSystemService(NotificationManager::class.java)
                .createNotificationChannel(NotificationChannel(CHANNEL, "다운로드", NotificationManager.IMPORTANCE_LOW))
        }

        private fun openIntent(context: android.content.Context): PendingIntent = PendingIntent.getActivity(
            context, FOREGROUND_ID,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(OPEN, true),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        private fun builder(context: android.content.Context) = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_playback)
            .setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == PAUSE) {
            events?.invokeMethod("pause", null)
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent == null) { stopSelf(); return START_NOT_STICKY }
        try {
            val progress = intent.getIntExtra("progress", -1)
            val name = intent.getStringExtra("name") ?: ""
            val phase = intent.getStringExtra("phase") ?: "파일 받는 중"
            val pause = PendingIntent.getService(this, FOREGROUND_ID,
                Intent(this, DownloadService::class.java).setAction(PAUSE),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val notification: Notification = builder(this)
                .setContentTitle(intent.getStringExtra("title") ?: "다운로드 중")
                .setContentText(if (progress < 0) "$name · $phase" else "$name · $phase ($progress%)")
                .setStyle(NotificationCompat.BigTextStyle().bigText("$name\n$phase"))
                .setContentIntent(openIntent(this))
                .setOngoing(true)
                .setProgress(100, progress.coerceAtLeast(0), progress < 0)
                .addAction(android.R.drawable.ic_media_pause, "전체 일시정지", pause)
                .build()
            startForeground(FOREGROUND_ID, notification)
            running = true
            if (wakeLock == null) {
                wakeLock = getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OPlayer:Download").apply {
                        setReferenceCounted(false)
                        acquire()
                    }
            }
            pendingStart?.success(null)
            pendingStart = null
        } catch (e: Exception) {
            pendingStart?.error("DOWNLOAD_SERVICE", e.message, null)
            pendingStart = null
            events?.invokeMethod("pause", null)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        events?.invokeMethod("timeout", null)
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        events?.invokeMethod("pause", null)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        pendingStart?.error("DOWNLOAD_SERVICE", "Download service stopped", null)
        pendingStart = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
