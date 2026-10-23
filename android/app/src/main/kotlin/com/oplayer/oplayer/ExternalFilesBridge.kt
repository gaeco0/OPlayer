package com.oplayer.oplayer

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

class ExternalFilesBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "oplayer/open_files")
    private val pending = mutableListOf<Map<String, String>>()
    private val granted = mutableSetOf<String>()
    private var ready = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    ready = true
                    result.success(pending.toList())
                    pending.clear()
                }
                "prepareImage" -> {
                    val value = call.arguments as? String
                    if (value == null || value !in granted) {
                        result.error("FILE", "No granted document", null)
                    } else {
                        // Only photos need a cache file for Flutter Image.file.
                        // Video/audio content URIs go straight to media_kit.
                        Thread {
                            var output: File? = null
                            try {
                                output = File.createTempFile("opened-photo-", ".image", activity.cacheDir)
                                activity.contentResolver.openInputStream(Uri.parse(value)).use { input ->
                                    requireNotNull(input) { "Cannot read document" }
                                    output.outputStream().use { sink ->
                                        val buffer = ByteArray(65536)
                                        var total = 0L
                                        while (true) {
                                            val read = input.read(buffer)
                                            if (read < 0) break
                                            total += read
                                            require(total <= 64L * 1024 * 1024) { "Image exceeds 64 MiB" }
                                            sink.write(buffer, 0, read)
                                        }
                                    }
                                }
                                val path = output.absolutePath
                                activity.runOnUiThread { result.success(path) }
                            } catch (_: Exception) {
                                output?.delete()
                                activity.runOnUiThread { result.error("FILE", "Cannot read image document", null) }
                            }
                        }.start()
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun accept(intent: Intent) {
        if (intent.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        if (uri.scheme !in listOf("content", "file")) return
        var name = uri.lastPathSegment.orEmpty()
        var mime = intent.type.orEmpty()
        if (uri.scheme == "content") {
            granted.add(uri.toString())
            try {
                activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0).orEmpty()
                }
                if (mime.isEmpty()) mime = activity.contentResolver.getType(uri).orEmpty()
                if (intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0 &&
                    intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0) {
                    activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            } catch (_: Exception) {
                // Some providers only grant temporary access or no metadata.
                // Keep the original URI; the decoder reports unreadable files.
            }
        }
        val entry = mapOf("uri" to uri.toString(), "name" to name, "mime" to mime)
        if (ready) channel.invokeMethod("open", listOf(entry)) else pending.add(entry)
    }
}
