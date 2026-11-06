package dev.libreshare.libreshare_app

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var multicastLock: MulticastLockChannel? = null
    private var deviceInfo: DeviceInfoChannel? = null
    private var fileOpener: FileOpenerChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Increment 2 is foreground-only (no foreground service yet). The moment the screen
        // times out or another app takes over, Android blocks this app's network access
        // (blocked_state=APP_BACKGROUND, observed on the AE emulator run) and any running
        // transfer stalls and then fails. Keeping the screen on while LibreShare is the
        // visible app is the only Kotlin-side way to let a long transfer finish. Costs battery
        // while the app sits open. TODO(Inc 3): drop this once a dataSync foreground service
        // (or a Dart-driven keep-awake only while a transfer is active) replaces it.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        multicastLock = MulticastLockChannel(applicationContext).also {
            it.register(flutterEngine.dartExecutor.binaryMessenger)
        }
        deviceInfo = DeviceInfoChannel(applicationContext).also {
            it.register(flutterEngine.dartExecutor.binaryMessenger)
        }
        fileOpener = FileOpenerChannel(applicationContext).also {
            it.register(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Foreground-only build (Increment 2): never leave the Wi-Fi multicast
        // filter off once the UI is gone.
        multicastLock?.dispose()
        multicastLock = null
        deviceInfo?.dispose()
        deviceInfo = null
        fileOpener?.dispose()
        fileOpener = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
