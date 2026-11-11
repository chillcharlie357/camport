package com.example.sony_camera

import android.Manifest
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.widget.Toast
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/** Lives with the Application/engine, never with an Activity or a second queue. */
class TransferBackgroundBridge(private val app: CameraTransferApplication) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var activity = WeakReference<MainActivity>(null)
    private var resumed = false
    private var closingTask = false
    private var pendingStart: MethodChannel.Result? = null
    private var startToken = 0L
    private var permissionInFlight = false
    private var pendingNetworkPrepare: MethodChannel.Result? = null
    private var localPermissionRequest: Pair<Int, String>? = null
    private var nextLocalPermissionRequestCode = 5_000
    internal var service: CameraTransferService? = null
        private set
    private val network = TransferNetwork(app) {
        emit("networkLost")
        failStart("network_lost", "Camera Wi-Fi was lost; reconnect before resuming")
        stopRuntime()
    }
    private val startDeadline = Runnable {
        failStart("foreground_start_timeout", "Android did not confirm foreground protection")
        stopRuntime()
    }

    val hasActivity: Boolean get() = activity.get() != null

    fun attachEngine(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    fun detachEngine() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    fun attachActivity(value: MainActivity) {
        activity = WeakReference(value)
        closingTask = false
    }

    fun activityResumed(value: MainActivity, valueResumed: Boolean) {
        if (activity.get() === value) resumed = valueResumed
    }

    fun detachActivity(value: MainActivity, finishing: Boolean) {
        if (activity.get() !== value) return
        activity.clear()
        resumed = false
        if (finishing) taskRemoved()
        else if (closingTask) scheduleClosedEngineCleanup()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    val count = number(call, "pendingFiles")
                    require(count in 1L..Int.MAX_VALUE.toLong()) { "pendingFiles must be a positive integer" }
                    beginStart(count.toInt(), result)
                }
                "update" -> {
                    val filename = call.argument<String>("filename")
                    require(!filename.isNullOrBlank()) { "filename is required" }
                    val bytes = number(call, "bytes")
                    val total = call.argument<Number>("total")?.toLong()
                    require(bytes >= 0 && (total == null || total >= 0)) { "Byte counts cannot be negative" }
                    val running = service ?: throw IllegalStateException("No active foreground transfer")
                    running.updateProgress(filename, bytes, total)
                    result.success(null)
                }
                "stop" -> {
                    cancelNetworkPreparation("网络准备已取消；需要时请重新连接相机。")
                    failStart("transfer_stopped", "Transfer protection was stopped before start completed")
                    stopRuntime()
                    result.success(null)
                }
                "prepareNetwork" -> prepareNetwork(result)
                "releaseNetwork" -> {
                    check(service == null && pendingStart == null) { "Stop the active transfer before releasing Wi-Fi" }
                    cancelNetworkPreparation("已取消网络准备并断开相机会话。")
                    network.release()
                    result.success(null)
                }
                "openWifiSettings" -> {
                    val host = activity.get()
                    check(host != null && resumed) { "Open Wi-Fi settings while the app is visible" }
                    try {
                        host.startActivity(Intent(if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_WIFI else Settings.ACTION_WIFI_SETTINGS))
                    } catch (_: ActivityNotFoundException) {
                        host.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: IllegalArgumentException) {
            result.error("invalid_arguments", error.message, null)
        } catch (error: IllegalStateException) {
            result.error("transfer_state", error.message, null)
        } catch (error: RuntimeException) {
            result.error("transfer_platform_error", error.message, error.javaClass.simpleName)
        }
    }

    private fun number(call: MethodCall, key: String): Long =
        (call.argument<Number>(key) ?: throw IllegalArgumentException("$key is required")).toLong()

    private fun requiredLocalNetworkPermission(): String? {
        // https://developer.android.com/privacy-and-security/local-network-permission
        val deviceSdk = Build.VERSION.SDK_INT
        val targetSdk = app.applicationInfo.targetSdkVersion
        return when {
            deviceSdk >= 37 && targetSdk >= 37 -> ACCESS_LOCAL_NETWORK
            // Android 16 opt-in uses NEARBY_WIFI_DEVICES. Its compatibility
            // change query is a hidden SystemApi, so do not reflect into it.
            // Ask at the explicit prepare action on Android 16, making both
            // stock and RESTRICT_LOCAL_NETWORK-enabled test devices safe.
            deviceSdk == 36 -> Manifest.permission.NEARBY_WIFI_DEVICES
            // Android 17 with target <= 36 receives the INTERNET split grant.
            // Android <= 15 has no LAN runtime permission for these raw sockets.
            else -> null
        }
    }

    @Suppress("DEPRECATION")
    private fun localNetworkPermissionFailure(): Map<String, Any?>? {
        val permission = requiredLocalNetworkPermission() ?: return null
        val declared = app.packageManager.getPackageInfo(app.packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions?.contains(permission) == true
        if (!declared) {
            return localNetworkDenied(
                permission, "missingDeclaration",
                "当前 Android 构建缺少 $permission 声明；请更新应用，不能将此状态当作相机掉线。",
            )
        }
        if (app.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) return null
        return localNetworkDenied(
            permission, "permissionRequired",
            "连接相机需要允许本地网络/附近设备权限（$permission）；请在应用前台授权，或到系统应用权限设置中允许。相机 Wi-Fi 不会因此自动连接。",
        )
    }

    private fun localNetworkDenied(permission: String?, status: String, message: String): Map<String, Any?> = mapOf(
        "connected" to false,
        "message" to message,
        "permission" to permission,
        "permissionStatus" to status,
    )

    private fun prepareNetwork(result: MethodChannel.Result) {
        val failure = localNetworkPermissionFailure()
        if (failure == null) {
            completeNetworkPreparation(result)
            return
        }
        if (failure["permissionStatus"] == "missingDeclaration") {
            result.success(failure)
            return
        }
        val permission = requiredLocalNetworkPermission() ?: return
        if (pendingNetworkPrepare != null || localPermissionRequest != null || permissionInFlight) {
            result.success(localNetworkDenied(permission, "requestInProgress", "权限申请正在进行；请完成系统提示后重试连接。"))
            return
        }
        val host = activity.get()
        if (host == null || !resumed || host.isFinishing || host.isDestroyed || closingTask) {
            result.success(localNetworkDenied(
                permission, "foregroundRequired",
                "尚未授予本地网络/附近设备权限（$permission）；请打开应用并重新连接相机，后台无法弹出权限申请。",
            ))
            return
        }
        // Keep only the MethodChannel Result and request identity on this bridge;
        // permission delivery survives Activity recreation without retaining it.
        val code = nextLocalPermissionRequestCode
        nextLocalPermissionRequestCode = if (code >= 65_535) 5_000 else code + 1
        pendingNetworkPrepare = result
        localPermissionRequest = code to permission
        try {
            host.requestPermissions(arrayOf(permission), code)
        } catch (_: RuntimeException) {
            pendingNetworkPrepare = null
            localPermissionRequest = null
            result.success(localNetworkDenied(permission, "requestUnavailable", "无法申请本地网络权限；请返回应用前台，或在系统应用权限设置中允许附近设备/本地网络后重试。"))
        }
    }

    private fun completeNetworkPreparation(result: MethodChannel.Result) {
        try {
            // Recheck after a system prompt: never bind or acquire a multicast
            // lock after a denial/revocation, and never turn it into networkLost.
            val failure = localNetworkPermissionFailure()
            if (failure != null) {
                result.success(failure)
            } else {
                result.success(network.prepare(
                    explicit = true, canReplace = service == null && pendingStart == null,
                ))
            }
        } catch (_: SecurityException) {
            result.success(localNetworkDenied(
                requiredLocalNetworkPermission(), "permissionDenied",
                "系统拒绝了本地网络访问权限；请在应用权限设置中允许附近设备/本地网络后重试，这不表示相机掉线。",
            ))
        } catch (error: RuntimeException) {
            result.error("network_prepare_failed", error.message, error.javaClass.simpleName)
        }
    }

    private fun cancelNetworkPreparation(message: String) {
        val result = pendingNetworkPrepare ?: return
        pendingNetworkPrepare = null
        // Keep the in-flight request identity until its callback, so another
        // prepare cannot stack a dialog or bind after this operation was canceled.
        result.success(localNetworkDenied(localPermissionRequest?.second, "cancelled", message))
    }

    private fun beginStart(count: Int, result: MethodChannel.Result) {
        val permissionFailure = localNetworkPermissionFailure()
        if (permissionFailure != null) {
            // start/background resume cannot request LAN permission or bypass a
            // denied prepareNetwork by binding directly through the service path.
            result.error("local_network_permission_required", permissionFailure["message"].toString(), permissionFailure)
            return
        }
        if (pendingStart != null) {
            result.error("start_in_progress", "Foreground protection is already starting", null)
            return
        }
        service?.let {
            it.pendingFiles = count
            result.success(notificationState())
            return
        }
        check(activity.get() != null && resumed && !closingTask) {
            "Start camera transfer while the app is visible, before returning to the background"
        }
        val route = network.prepare(explicit = false)
        check(route["connected"] == true) { route["message"].toString() }
        pendingStart = result
        val token = ++startToken
        main.postDelayed(startDeadline, 15_000)
        try {
            val intent = Intent(app, CameraTransferService::class.java)
                .setAction(CameraTransferService.ACTION_START)
                .putExtra("token", token)
                .putExtra("pendingFiles", count)
            if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(intent) else app.startService(intent)
        } catch (error: RuntimeException) {
            failStart("foreground_start_failed", error.message ?: "Android refused the foreground service")
            stopRuntime()
        }
    }

    internal fun acceptsStart(token: Long): Boolean = pendingStart != null && startToken == token

    internal fun serviceStarted(value: CameraTransferService, token: Long) {
        if (!acceptsStart(token)) {
            value.finishTransfer()
            return
        }
        service = value
        main.removeCallbacks(startDeadline)
        val host = activity.get()
        if (Build.VERSION.SDK_INT >= 33 &&
            app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            host != null && resumed && !permissionInFlight
        ) {
            // Request only for this explicit user-started transfer, never on launch.
            // The Result stays on this process bridge across Activity recreation.
            permissionInFlight = true
            try {
                host.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_REQUEST)
                return
            } catch (_: RuntimeException) {
                permissionInFlight = false
            }
        }
        completeStart()
    }

    fun onPermissionResult(requestCode: Int) {
        val localRequest = localPermissionRequest
        if (localRequest != null && requestCode == localRequest.first) {
            localPermissionRequest = null
            val result = pendingNetworkPrepare ?: return
            pendingNetworkPrepare = null
            if (app.checkSelfPermission(localRequest.second) != PackageManager.PERMISSION_GRANTED) {
                result.success(localNetworkDenied(
                    localRequest.second, "permissionDenied",
                    "本地网络/附近设备权限未获允许（${localRequest.second}）；请在系统应用权限设置中允许后重试。应用未自动连接相机或切换 Wi-Fi。",
                ))
            } else {
                // This completes the caller's explicit prepare only: bind the
                // already-connected Wi-Fi, never join an AP or start discovery/PTP.
                completeNetworkPreparation(result)
            }
            return
        }
        if (requestCode != NOTIFICATION_REQUEST) return
        permissionInFlight = false
        if (service != null) {
            val state = notificationState()
            if (state["notificationsEnabled"] == false) {
                Toast.makeText(app, state["message"].toString(), Toast.LENGTH_LONG).show()
            }
            completeStart()
        }
    }

    private fun completeStart() {
        val result = pendingStart ?: return
        pendingStart = null
        result.success(notificationState())
    }

    private fun notificationState(): Map<String, Any> {
        val manager = requireNotNull(app.getSystemService(NotificationManager::class.java))
        val denied = Build.VERSION.SDK_INT >= 33 &&
            app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        val channelBlocked = Build.VERSION.SDK_INT >= 26 &&
            manager.getNotificationChannel(CameraTransferService.NOTIFICATION_CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE
        val state = when {
            denied -> "permissionDenied"
            !manager.areNotificationsEnabled() -> "appBlocked"
            channelBlocked -> "channelBlocked"
            else -> "enabled"
        }
        return mapOf(
            "notificationsEnabled" to (state == "enabled"),
            "notificationStatus" to state,
            "message" to when (state) {
                "permissionDenied" -> "前台传输服务已运行；通知权限被拒绝，仅可在系统活动应用中查看和停止。"
                "appBlocked", "channelBlocked" -> "前台传输服务已运行；系统已关闭传输通知，请在系统设置中开启。"
                else -> "前台传输服务已运行，持续通知已开启。"
            },
        )
    }

    internal fun serviceFailed(value: CameraTransferService, error: RuntimeException) {
        val starting = pendingStart != null
        failStart("foreground_start_failed", error.message ?: "Could not protect the camera transfer")
        if (!starting) emit("budgetExpired")
        value.finishTransfer()
        network.releaseAfterTransfer()
    }

    internal fun serviceStopped(value: CameraTransferService) {
        if (service === value) service = null
        network.releaseAfterTransfer()
    }

    internal fun serviceDestroyed(value: CameraTransferService) {
        if (service === value) {
            service = null
            emit("budgetExpired")
            failStart("service_destroyed", "Android stopped foreground protection")
            network.releaseAfterTransfer()
        }
    }

    internal fun interrupt(event: String) {
        emit(event)
        failStart("transfer_interrupted", "Transfer interrupted: $event")
        stopRuntime()
    }

    internal fun engineStopping() {
        cancelNetworkPreparation("Dart 引擎已停止；下次打开应用后可重新申请本地网络权限。")
        localPermissionRequest = null
        failStart("engine_stopped", "The Dart engine stopped; resume the persisted queue on next launch")
        try {
            stopRuntime()
        } finally {
            network.release()
        }
    }

    internal fun taskRemoved() {
        closingTask = true
        cancelNetworkPreparation("应用已关闭，未继续准备网络；请重新打开应用后连接相机。")
        localPermissionRequest = null
        permissionInFlight = false
        if (service != null || pendingStart != null) emit("pauseRequested")
        failStart("task_closed", "The application task was closed")
        try {
            stopRuntime()
        } finally {
            try {
                network.release()
            } finally {
                // Give Dart's pause/persist callback a turn, then destroy the idle engine.
                // Activity detach happens first; opening a new Activity cancels this path.
                scheduleClosedEngineCleanup()
            }
        }
    }

    private fun emit(event: String) {
        channel?.invokeMethod("event", event)
    }

    private fun scheduleClosedEngineCleanup() {
        main.postDelayed({ if (closingTask && !hasActivity) app.destroyClosedTaskEngine() }, 1_000)
    }

    private fun failStart(code: String, message: String) {
        main.removeCallbacks(startDeadline)
        val result = pendingStart
        pendingStart = null
        result?.error(code, message, null)
    }

    private fun stopRuntime() {
        service?.finishTransfer()
        app.stopService(Intent(app, CameraTransferService::class.java))
        network.releaseAfterTransfer()
    }

    companion object {
        const val CHANNEL = "sony_camera/transfer_background"
        private const val NOTIFICATION_REQUEST = 4317
        // String keeps compileSdk 36 compatible; do not request on target < 37.
        private const val ACCESS_LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
    }
}
