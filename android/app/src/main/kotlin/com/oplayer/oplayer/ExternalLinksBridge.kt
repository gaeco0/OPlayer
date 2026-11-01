package com.oplayer.oplayer

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class ExternalLinksBridge(private val activity: Activity, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "oplayer/externalLinks").setMethodCallHandler { call, result ->
            if (call.method != "openIntent") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val url = call.arguments as? String ?: error("Missing intent URL")
                require(url.startsWith("intent:"))
                val parsed = Intent.parseUri(url, Intent.URI_INTENT_SCHEME)
                val data = parsed.data ?: error("Missing intent target")
                require(data.scheme != null && data.scheme!!.lowercase() !in listOf(
                    "intent", "file", "content", "javascript", "vbscript", "data", "blob", "about"
                ))
                // Only launch a browsable VIEW. Never forward a supplied component,
                // selector, grant flags, action or arbitrary extras from a website.
                val target = Intent(Intent.ACTION_VIEW, data).addCategory(Intent.CATEGORY_BROWSABLE)
                parsed.`package`?.let { target.setPackage(it) }
                activity.startActivity(target)
                result.success(true)
            } catch (_: ActivityNotFoundException) {
                result.success(false)
            } catch (_: Exception) {
                result.success(false)
            }
        }
    }
}
