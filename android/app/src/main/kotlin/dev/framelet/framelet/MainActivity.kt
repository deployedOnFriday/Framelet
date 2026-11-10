package dev.framelet.framelet

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.app.UiModeManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "framelet/device",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isTelevision" -> result.success(isTelevision())
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "framelet/update",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "installApk" ->
                        result.success(installApk(call.argument<String>("path")))
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        requireNotNull(url) { "URL is required" }
                        startActivity(
                            Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("update_failed", error.message, null)
            }
        }
    }

    /** 电视、机顶盒、投影等 Leanback 设备返回 true。 */
    private fun isTelevision(): Boolean {
        val manager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        return manager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
    }

    private fun installApk(path: String?): Boolean {
        requireNotNull(path) { "APK path is required" }
        val file = File(path)
        require(file.isFile) { "APK not found" }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            val settings = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(settings)
            return false
        }
        val apk = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )
        val install = Intent(Intent.ACTION_VIEW)
            .setDataAndType(apk, "application/vnd.android.package-archive")
            .addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_ACTIVITY_NEW_TASK,
            )
        try {
            startActivity(install)
            return true
        } catch (_: ActivityNotFoundException) {
            throw IllegalStateException("No APK installer found")
        }
    }
}
