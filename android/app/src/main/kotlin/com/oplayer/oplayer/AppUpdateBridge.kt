package com.oplayer.oplayer

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class AppUpdateBridge(private val activity: Activity, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "oplayer/updates").setMethodCallHandler { call, result ->
            when (call.method) {
                "abis" -> result.success(Build.SUPPORTED_ABIS.toList())
                "install" -> {
                    val path = call.argument<String>("path")
                    val hash = call.argument<String>("sha256")
                    if (path == null || hash == null || !Regex("^[0-9a-f]{64}$").matches(hash)) {
                        result.error("UPDATE", "Invalid update metadata", null)
                    } else Thread {
                        try {
                            val file = File(path).canonicalFile
                            val directory = File(activity.cacheDir, "updates").canonicalFile
                            require(file.parentFile == directory && file.extension == "apk" && file.isFile) { "Invalid update path" }
                            val digest = MessageDigest.getInstance("SHA-256")
                            file.inputStream().use { input ->
                                val buffer = ByteArray(65536)
                                while (true) { val size = input.read(buffer); if (size < 0) break; digest.update(buffer, 0, size) }
                            }
                            require(digest.digest().joinToString("") { "%02x".format(it) } == hash) { "Update checksum mismatch" }
                            @Suppress("DEPRECATION")
                            val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
                            @Suppress("DEPRECATION")
                            val archive = activity.packageManager.getPackageArchiveInfo(file.path, flags)
                                ?: error("Invalid APK")
                            @Suppress("DEPRECATION")
                            val installed = activity.packageManager.getPackageInfo(activity.packageName, flags)
                            require(archive.packageName == activity.packageName) { "Wrong update package" }
                            @Suppress("DEPRECATION")
                            val sameSigner = if (Build.VERSION.SDK_INT >= 28) {
                                archive.signingInfo?.apkContentsSigners?.toSet() == installed.signingInfo?.apkContentsSigners?.toSet() && archive.signingInfo != null
                            } else archive.signatures?.toSet() == installed.signatures?.toSet() && archive.signatures != null
                            require(sameSigner) { "Update signing certificate differs" }
                            @Suppress("DEPRECATION")
                            val allowedVersion = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode >= installed.longVersionCode else archive.versionCode >= installed.versionCode
                            require(allowedVersion) { "The system does not allow this older build" }
                            activity.runOnUiThread {
                                try {
                                    if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                                        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
                                        result.success("permission")
                                    } else {
                                        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
                                        activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                        result.success("opened")
                                    }
                                } catch (error: Exception) { result.error("UPDATE", error.message, null) }
                            }
                        } catch (error: Exception) {
                            activity.runOnUiThread { result.error("UPDATE", error.message, null) }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }
}
