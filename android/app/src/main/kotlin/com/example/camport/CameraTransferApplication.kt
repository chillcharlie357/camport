package com.example.camport

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class CameraTransferApplication : Application() {
    val transfers by lazy { TransferBackgroundBridge(this) }
    private var engine: FlutterEngine? = null

    // Deliberately lazy: a stale service/notification intent must not run main()
    // or resurrect downloads. Only opening the Activity obtains an engine.
    fun obtainEngine(): FlutterEngine {
        engine?.let { return it }
        return FlutterEngine(this).also {
            // FlutterEngine registers generated plugins once at construction.
            // Activity supplies the initial route/entrypoint and starts Dart.
            transfers.attachEngine(it)
            it.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() {
                    transfers.engineStopping()
                }

                override fun onEngineWillDestroy() {
                    transfers.engineStopping()
                }
            })
            engine = it
            FlutterEngineCache.getInstance().put(ENGINE_ID, it)
        }
    }

    fun destroyClosedTaskEngine() {
        if (transfers.hasActivity) return
        transfers.detachEngine()
        FlutterEngineCache.getInstance().remove(ENGINE_ID)
        engine?.destroy()
        engine = null
    }

    companion object {
        private const val ENGINE_ID = "camport.main"
    }
}
