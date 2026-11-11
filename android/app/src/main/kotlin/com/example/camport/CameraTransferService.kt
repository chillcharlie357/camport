package com.example.camport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log

/** Protects the Application's existing Dart engine; contains no transfer worker. */
class CameraTransferService : Service() {
    private val bridge get() = (application as CameraTransferApplication).transfers
    private val main = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var active = false
    private var lastNotificationAt = 0L
    private var filename: String? = null
    private var bytes = 0L
    private var total: Long? = null
    var pendingFiles = 0
    private val expire = Runnable { bridge.interrupt("budgetExpired") }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_PAUSE) {
            if (active) bridge.interrupt("pauseRequested") else stopSelf()
            return START_NOT_STICKY
        }
        val token = intent?.getLongExtra("token", -1) ?: -1
        if (intent?.action != ACTION_START || !bridge.acceptsStart(token)) {
            // No sticky resurrection, independent engine, or automatic queue replay.
            if (!active) stopSelf()
            return START_NOT_STICKY
        }
        try {
            pendingFiles = intent.getIntExtra("pendingFiles", 0)
            createNotificationChannel()
            val notification = notification()
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            acquireLocks()
            active = true
            main.postDelayed(expire, MAX_SESSION_MS)
            // Only acknowledge protection after promotion AND lock acquisition.
            bridge.serviceStarted(this, token)
        } catch (error: RuntimeException) {
            bridge.serviceFailed(this, error)
        }
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        val wake = requireNotNull(getSystemService(PowerManager::class.java))
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "camport:transfer")
        wakeLock = wake
        wake.setReferenceCounted(false)
        // Bounded independently of the service's watchdog, even on error.
        wake.acquire(MAX_SESSION_MS + 5_000)
        // API 34+ maps HIGH_PERF to LOW_LATENCY with foreground/screen-on limits.
        // Screen-off execution depends on the foreground service, partial wake
        // lock and retained Wi-Fi Network, not on legacy high-performance behavior.
        val wifi = requireNotNull(applicationContext.getSystemService(WifiManager::class.java))
            .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "camport:transfer")
        wifiLock = wifi
        wifi.setReferenceCounted(false)
        wifi.acquire()
    }

    fun updateProgress(nextFilename: String, nextBytes: Long, nextTotal: Long?) {
        check(active) { "Foreground protection is no longer active" }
        val changedFile = filename != nextFilename
        filename = nextFilename
        bytes = nextBytes
        total = nextTotal
        val now = android.os.SystemClock.elapsedRealtime()
        // Keep progress useful without flooding Android's notification manager.
        if (changedFile || now - lastNotificationAt >= 1_000 || (total != null && bytes >= total!!)) {
            try {
                requireNotNull(getSystemService(NotificationManager::class.java)).notify(NOTIFICATION_ID, notification())
                lastNotificationAt = now
            } catch (error: RuntimeException) {
                bridge.serviceFailed(this, error)
                throw error
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            requireNotNull(getSystemService(NotificationManager::class.java)).createNotificationChannel(
                NotificationChannel(NOTIFICATION_CHANNEL, "相机文件传输", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "显示相机原始文件传输进度，并可停止传输"
                    setShowBadge(false)
                },
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val pause = PendingIntent.getService(
            this, 1, Intent(this, CameraTransferService::class.java).setAction(ACTION_PAUSE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, NOTIFICATION_CHANNEL) else Notification.Builder(this)
        val expected = total
        val progress = if (expected != null && expected > 0) {
            ((bytes.toDouble() / expected.toDouble()) * 1_000).toInt().coerceIn(0, 1_000)
        } else 0
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("正在从相机传输 · $pendingFiles 个文件")
            .setContentText(filename?.let { "$it · $bytes${expected?.let { size -> " / $size" } ?: ""} 字节" } ?: "相机传输已受前台服务保护")
            .setContentIntent(open)
            .setDeleteIntent(pause)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setPriority(Notification.PRIORITY_LOW)
            .setProgress(1_000, progress, expected == null || expected <= 0)
            .apply {
                if (Build.VERSION.SDK_INT >= 31) {
                    setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                }
            }
            .addAction(Notification.Action.Builder(null, "停止传输", pause).build())
            .build()
    }

    fun finishTransfer() {
        active = false
        releaseResources()
        try {
            bridge.serviceStopped(this)
        } finally {
            try {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } finally {
                stopSelf()
            }
        }
    }

    private fun releaseResources() {
        main.removeCallbacks(expire)
        // Independent cleanup ensures one failure cannot leak the other lock.
        val wifi = wifiLock
        wifiLock = null
        val wake = wakeLock
        wakeLock = null
        runCatching { if (wifi?.isHeld == true) wifi.release() }
            .onFailure { Log.w("CameraTransfer", "Could not release Wi-Fi lock", it) }
        runCatching { if (wake?.isHeld == true) wake.release() }
            .onFailure { Log.w("CameraTransfer", "Could not release wake lock", it) }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        bridge.taskRemoved()
        super.onTaskRemoved(rootIntent)
    }

    override fun onTimeout(startId: Int) {
        bridge.interrupt("budgetExpired")
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        bridge.interrupt("budgetExpired")
    }

    override fun onDestroy() {
        releaseResources()
        try {
            bridge.serviceDestroyed(this)
        } finally {
            stopForeground(STOP_FOREGROUND_REMOVE)
            super.onDestroy()
        }
    }

    companion object {
        const val ACTION_START = "com.example.camport.TRANSFER_START"
        const val ACTION_PAUSE = "com.example.camport.TRANSFER_PAUSE"
        const val NOTIFICATION_CHANNEL = "camera_transfer"
        private const val NOTIFICATION_ID = 4317
        // App safety budget, NOT an Android connectedDevice time limit.
        // Dart receives budgetExpired and can persist remaining work for a new session.
        private const val MAX_SESSION_MS = 6 * 60 * 60 * 1_000L
    }
}
