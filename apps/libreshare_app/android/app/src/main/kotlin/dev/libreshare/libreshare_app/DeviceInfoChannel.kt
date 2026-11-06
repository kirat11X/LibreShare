package dev.libreshare.libreshare_app

import android.content.Context
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Channel `dev.libreshare/device_info`, method `deviceName` (no arguments): the name the user gave
 * the phone (Settings.Global "device_name"), else Build.MODEL. May answer null or empty; the Dart
 * side falls back. Never throws for a missing setting.
 *
 * UNVERIFIED on a device (written for the F3 contract; compiled by `flutter build apk`).
 */
class DeviceInfoChannel(private val context: Context) : MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceName" -> {
                val name = try {
                    Settings.Global.getString(context.contentResolver, "device_name")
                } catch (e: Exception) {
                    null
                }
                result.success(if (name.isNullOrBlank()) Build.MODEL else name)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL = "dev.libreshare/device_info"
    }
}
