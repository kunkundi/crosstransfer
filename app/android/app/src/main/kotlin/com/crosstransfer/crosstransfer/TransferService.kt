package com.crosstransfer.crosstransfer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class TransferService : Service() {
    private var wake_lock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel("transfer", getString(R.string.transfer_channel), NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "transfer") else Notification.Builder(this)
        val notification = builder.setSmallIcon(R.drawable.ic_transfer)
            .setContentTitle("CrossTransfer").setContentText(getString(R.string.transfer_running))
            .setContentIntent(open).setOngoing(true).setCategory(Notification.CATEGORY_PROGRESS).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(701, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(701, notification)
        wake_lock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CrossTransfer:transfer").also {
            it.acquire(6 * 60 * 60 * 1000L)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_NOT_STICKY
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTimeout(startId: Int, fgsType: Int) {
        (application as TransferApplication).mobile.BackgroundExpired()
        stopSelf()
    }

    override fun onDestroy() {
        wake_lock?.let { if (it.isHeld) it.release() }
        wake_lock = null
        super.onDestroy()
    }
}
