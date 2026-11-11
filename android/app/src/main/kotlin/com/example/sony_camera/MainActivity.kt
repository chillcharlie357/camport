package com.example.sony_camera

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val transfers get() = (application as CameraTransferApplication).transfers

    // Android's provider API is distinct from iOS's implicit-engine delegate.
    // The Application owns this one engine; onStart runs Dart only the first time.
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as CameraTransferApplication).obtainEngine()

    override fun shouldDestroyEngineWithHost(): Boolean = false

    // The retained engine already contains the live UI/runner state. Replaying
    // a destroyed Activity's restoration payload would be stale.
    override fun shouldRestoreAndSaveState(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        transfers.attachActivity(this)
    }

    override fun onResume() {
        super.onResume()
        transfers.activityResumed(this, true)
    }

    override fun onPause() {
        transfers.activityResumed(this, false)
        super.onPause()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        transfers.onPermissionResult(requestCode)
    }

    override fun onDestroy() {
        // Detach the Flutter view/plugins before considering engine destruction.
        super.onDestroy()
        transfers.detachActivity(this, isFinishing && !isChangingConfigurations)
    }
}
