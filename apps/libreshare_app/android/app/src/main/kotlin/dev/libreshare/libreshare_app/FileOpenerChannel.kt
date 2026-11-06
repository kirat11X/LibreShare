package dev.libreshare.libreshare_app

import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Channel `dev.libreshare/file_opener`: `open` and `showInFolder`, arguments `{ "path": <saved FILE
 * path> }`. Answers true only if an activity was started; false if the file is missing or nothing
 * can handle it. Unexpected failures answer `error` (Dart treats it as false). No storage
 * permission is needed: the viewer gets a one-time read grant through FileProvider.
 *
 * UNVERIFIED on a device (written for the F3 contract; compiled by `flutter build apk`).
 */
class FileOpenerChannel(private val context: Context) : MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.error("bad_args", "path is required", null)
            return
        }
        try {
            when (call.method) {
                "open" -> result.success(open(File(path)))
                "showInFolder" -> result.success(showInFolder(File(path)))
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("failed", e.javaClass.simpleName, null)
        }
    }

    private fun isAllowedFile(file: File): Boolean {
        if (!file.isFile) return false
        val canonical = try {
            file.canonicalFile
        } catch (_: Exception) {
            return false
        }
        if (!canonical.isFile) return false
        val cPath = canonical.canonicalPath

        // Refuse private app data prefix
        if (cPath.startsWith("/data/") || cPath == "/data") return false

        // Must be under external storage or app's external files dir
        val extStorage = Environment.getExternalStorageDirectory()?.canonicalPath
        val extFiles = context.getExternalFilesDir(null)?.canonicalPath

        val underExtStorage = extStorage != null && (cPath == extStorage || cPath.startsWith("$extStorage/"))
        val underExtFiles = extFiles != null && (cPath == extFiles || cPath.startsWith("$extFiles/"))

        return underExtStorage || underExtFiles
    }

    private fun open(file: File): Boolean {
        if (!isAllowedFile(file)) return false
        val canonical = file.canonicalFile
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", canonical)
        val ext = canonical.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        return start(intent)
    }

    private fun showInFolder(file: File): Boolean {
        if (!isAllowedFile(file)) return false
        val canonical = file.canonicalFile
        val dir = canonical.parentFile ?: return false
        val root = Environment.getExternalStorageDirectory().canonicalPath
        val dirPath = dir.canonicalPath
        if (dirPath == root || dirPath.startsWith("$root/")) {
            val relative = dirPath.removePrefix(root).trim('/')
            val docUri = Uri.parse(
                "content://com.android.externalstorage.documents/document/primary%3A" +
                    Uri.encode(relative)
            )
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(docUri, "vnd.android.document/directory")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (start(intent)) return true
            val downloads = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS
            ).canonicalPath
            if (dirPath == downloads || dirPath.startsWith("$downloads/")) {
                val view = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                return start(view)
            }
        }
        return false
    }

    private fun start(intent: Intent): Boolean = try {
        context.startActivity(intent)
        true
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: SecurityException) {
        false
    }

    companion object {
        const val CHANNEL = "dev.libreshare/file_opener"
    }
}
