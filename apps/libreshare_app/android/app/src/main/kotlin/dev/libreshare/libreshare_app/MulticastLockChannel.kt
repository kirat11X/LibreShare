package dev.libreshare.libreshare_app

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Reference-counted `WifiManager.MulticastLock` behind the Dart channel
 * `dev.libreshare/multicast_lock` (see lib/platform/android/multicast_lock_android.dart).
 *
 * Methods: `acquire`, `release` (both answer the new holder count), `isHeld`.
 * The platform lock itself is created non-reference-counted: this class owns the
 * counting so that "two acquires, one release" keeps the lock held.
 *
 * UNVERIFIED: written without an Android SDK on the dev box; not compiled or run.
 */
class MulticastLockChannel(context: Context) : MethodChannel.MethodCallHandler {
    private val wifi: WifiManager? =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private var lock: WifiManager.MulticastLock? = null
    private var holders = 0
    private var channel: MethodChannel? = null

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    /** Releases everything and detaches from the engine (activity destroyed). */
    @Synchronized
    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
        holders = 0
        releasePlatformLock()
    }

    @Synchronized
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "acquire" -> {
                val manager = wifi
                if (manager == null) {
                    result.error("unavailable", "WifiManager not available", null)
                    return
                }
                try {
                    val held = lock ?: manager.createMulticastLock(TAG).also {
                        it.setReferenceCounted(false)
                        lock = it
                    }
                    if (!held.isHeld) held.acquire()
                    holders++
                    result.success(holders)
                } catch (e: SecurityException) {
                    // CHANGE_WIFI_MULTICAST_STATE missing from the manifest.
                    result.error("permission", e.message, null)
                } catch (e: RuntimeException) {
                    Log.w(TAG, "multicast lock acquire failed", e)
                    result.error("acquire_failed", e.message, null)
                }
            }
            "release" -> {
                if (holders > 0) holders--
                if (holders == 0) releasePlatformLock()
                result.success(holders)
            }
            "isHeld" -> result.success(lock?.isHeld == true)
            else -> result.notImplemented()
        }
    }

    private fun releasePlatformLock() {
        try {
            lock?.takeIf { it.isHeld }?.release()
        } catch (e: RuntimeException) {
            Log.w(TAG, "multicast lock release failed", e)
        }
    }

    companion object {
        const val CHANNEL = "dev.libreshare/multicast_lock"
        const val TAG = "libreshare"
    }
}
