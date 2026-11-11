package com.example.sony_camera

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.net.Inet4Address

/** Process-wide route shared by the UI's PTP session and the foreground service. */
internal class TransferNetwork(context: Context, private val onLost: () -> Unit) {
    private val connectivity = requireNotNull(context.getSystemService(ConnectivityManager::class.java))
    private val wifiManager = requireNotNull(context.applicationContext.getSystemService(WifiManager::class.java))
    private val main = Handler(Looper.getMainLooper())
    private var selected: Network? = null
    private var previousBinding: Network? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var retention: ConnectivityManager.NetworkCallback? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var explicitlyPrepared = false
    private var lost = false

    fun prepare(explicit: Boolean, canReplace: Boolean = true): Map<String, Any?> {
        val current = selected
        if (current != null && !lost && isWifi(current)) {
            check(connectivity.bindProcessToNetwork(current)) { "Could not retain the camera Wi-Fi route" }
            acquireMulticast()
            explicitlyPrepared = explicitlyPrepared || explicit
            return description(current)
        }
        check(canReplace) { "Stop the active transfer before changing its Wi-Fi route" }
        // No INTERNET/VALIDATED requirement: a camera DIRECT AP is normally offline.
        val wifi = connectivity.allNetworks.firstOrNull { isWifi(it) }
            ?: return mapOf(
                "connected" to false,
                "message" to "请在系统 Wi-Fi 设置中手动连接相机 DIRECT 网络，再重试。不会使用移动网络传输。",
            )
        release()
        previousBinding = connectivity.boundNetworkForProcess
        selected = wifi
        explicitlyPrepared = explicit
        lost = false
        try {
            check(connectivity.bindProcessToNetwork(wifi)) { "Could not bind to the connected Wi-Fi" }
            acquireMulticast()
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            val observer = object : ConnectivityManager.NetworkCallback() {
                override fun onLost(network: Network) {
                    main.post {
                        if (callback === this && selected == network && !lost) {
                            lost = true
                            unregister()
                            releaseMulticast()
                            // Keep the dead route pinned until explicit release/retry.
                            // New PTP sockets must fail rather than fall back to cellular.
                            onLost()
                        }
                    }
                }
            }
            callback = observer
            // Observe ALL matching networks so a best-network change cannot hide
            // the loss of the particular network that PTP sockets are pinned to.
            connectivity.registerNetworkCallback(request, observer)
            // Separately retain the already-connected Wi-Fi. No SSID scanning,
            // network specifier, credentials, or app-driven AP connection.
            val keeper = ConnectivityManager.NetworkCallback()
            retention = keeper
            connectivity.requestNetwork(request, keeper)
            check(isWifi(wifi)) { "Camera Wi-Fi disconnected while preparing its route" }
            return description(wifi)
        } catch (error: RuntimeException) {
            release()
            throw error
        }
    }

    fun releaseAfterTransfer() {
        // An explicitly prepared PTP session belongs to the caller until disconnect.
        if (!explicitlyPrepared && !lost) release()
    }

    fun release() {
        unregister()
        releaseMulticast()
        val pinned = selected
        try {
            if (pinned != null && connectivity.boundNetworkForProcess == pinned) {
                if (!connectivity.bindProcessToNetwork(previousBinding)) {
                    check(connectivity.bindProcessToNetwork(null)) { "Could not release the camera Wi-Fi route" }
                }
            }
        } finally {
            selected = null
            previousBinding = null
            explicitlyPrepared = false
            lost = false
        }
    }

    private fun unregister() {
        val observers = listOfNotNull(callback, retention)
        callback = null
        retention = null
        // Also safe when requestNetwork threw before the registration completed.
        observers.forEach { observer -> runCatching { connectivity.unregisterNetworkCallback(observer) } }
    }

    private fun acquireMulticast() {
        if (multicastLock?.isHeld == true) return
        // SSDP 239.255.255.250:1900 responses may otherwise be filtered by Wi-Fi.
        // Owned by the connected session, never a permanent Application lock.
        val lock = wifiManager.createMulticastLock("sony_camera:ssdp")
        multicastLock = lock
        lock.setReferenceCounted(false)
        lock.acquire()
    }

    private fun releaseMulticast() {
        val lock = multicastLock
        multicastLock = null
        runCatching { if (lock?.isHeld == true) lock.release() }
            .onFailure { Log.w("CameraTransfer", "Could not release multicast lock", it) }
    }

    private fun isWifi(network: Network): Boolean =
        connectivity.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true

    private fun description(network: Network): Map<String, Any?> {
        val gateway = connectivity.getLinkProperties(network)?.routes
            ?.firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }
            ?.gateway?.hostAddress
        return mapOf(
            "connected" to true,
            "message" to "已绑定当前 Wi-Fi；请确认这是相机的 DIRECT 网络。",
            "host" to gateway,
        )
    }
}
