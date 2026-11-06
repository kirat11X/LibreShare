package dev.libreshare.libreshare_app

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
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android Foreground Service managing background file reception (Card F4 / U1).
 *
 * Implements Android 14+ foreground service types:
 * - FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE (F0 primary)
 * - FOREGROUND_SERVICE_TYPE_DATA_SYNC (F1 fallback)
 *
 * Handles onTimeout callbacks required by Android 14+ for dataSync types.
 */
class ReceiveService : Service() {
    companion object {
        const val CHANNEL_ID = "dev.libreshare.receive_service"
        const val NOTIFICATION_ID = 4001

        const val ACTION_START = "dev.libreshare.action.START_RECEIVE"
        const val ACTION_STOP = "dev.libreshare.action.STOP_RECEIVE"

        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_BODY = "extra_body"
        const val EXTRA_TYPE = "extra_type"

        var isRunning: Boolean = false
            private set

        private var activeMethodChannel: MethodChannel? = null

        fun setMethodChannel(channel: MethodChannel?) {
            activeMethodChannel = channel
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null || intent.action == ACTION_STOP) {
            stopForegroundService()
            return START_NOT_STICKY
        }

        if (intent.action == ACTION_START) {
            val title = intent.getStringExtra(EXTRA_TITLE) ?: "LibreShare"
            val body = intent.getStringExtra(EXTRA_BODY) ?: "Ready to receive files"
            val typeStr = intent.getStringExtra(EXTRA_TYPE) ?: "connectedDevice"

            val notification = buildNotification(title, body)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val fgsType = when (typeStr) {
                    "dataSync" -> ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                    else -> ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                }
                startForeground(NOTIFICATION_ID, notification, fgsType)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }

            isRunning = true
        }

        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        super.onTimeout(startId, fgsType)
        // Notify Dart layer via MethodChannel
        activeMethodChannel?.invokeMethod("onTimeout", mapOf(
            "startId" to startId,
            "fgsType" to fgsType
        ))
        stopForegroundService()
    }

    private fun stopForegroundService() {
        isRunning = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                CHANNEL_ID,
                "LibreShare Receive Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps LibreShare ready to receive files in background"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, body: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
