package com.oplayer.oplayer

import android.accounts.Account
import android.app.Activity
import android.content.Intent
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class GoogleDriveBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "oplayer/google-drive")
    private val client = Identity.getAuthorizationClient(activity)
    private var pending: MethodChannel.Result? = null
    private val requestCode = 7934

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "syncDeviceId") {
                try {
                    val file = java.io.File(activity.noBackupFilesDir, "oplayer-sync-device")
                    val saved = if (file.exists()) file.readText() else null
                    val id = try { java.util.UUID.fromString(saved).toString() }
                        catch (_: Exception) { java.util.UUID.randomUUID().toString() }
                    if (id != saved) file.writeText(id)
                    result.success(id)
                } catch (e: Exception) { result.error("SYNC_DEVICE", "기기 동기화 ID를 저장하지 못했습니다", null) }
                return@setMethodCallHandler
            }
            if (call.method == "registrationInfo") {
                @Suppress("DEPRECATION")
                val signature = activity.packageManager.getPackageInfo(activity.packageName,
                    android.content.pm.PackageManager.GET_SIGNATURES).signatures?.firstOrNull()
                val sha1 = signature?.let { java.security.MessageDigest.getInstance("SHA-1").digest(it.toByteArray())
                    .joinToString(":") { byte -> "%02X".format(byte.toInt() and 0xff) } }
                result.success(mapOf("package" to activity.packageName, "sha1" to sha1))
                return@setMethodCallHandler
            }
            if (call.method != "authorize") { result.notImplemented(); return@setMethodCallHandler }
            if (pending != null) { result.error("BUSY", "이미 Google 로그인 중입니다", null); return@setMethodCallHandler }
            val scopes = call.argument<List<String>>("scopes")
                ?: listOf("https://www.googleapis.com/auth/drive.readonly")
            val allowed = setOf("https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/drive.appdata",
                "https://www.googleapis.com/auth/drive")
            if (scopes.isEmpty() || scopes.any { it !in allowed }) {
                result.error("SCOPE", "지원하지 않는 Google 권한입니다", null)
                return@setMethodCallHandler
            }
            pending = result
            val email = call.argument<String>("email")
            val interactive = call.argument<Boolean>("interactive") == true
            val oldToken = call.argument<String>("invalidateToken")
            val request = AuthorizationRequest.builder()
                .setRequestedScopes(scopes.map { Scope(it) })
                .apply { if (!email.isNullOrBlank()) setAccount(Account(email, "com.google")) }
                .build()
            fun authorize() {
                client.authorize(request).addOnSuccessListener { authorization ->
                    if (pending == null) return@addOnSuccessListener
                    if (authorization.hasResolution()) {
                        if (!interactive) {
                            fail("REAUTH", "Google Drive 계정을 다시 연결해 주세요")
                        } else {
                            try {
                                activity.startIntentSenderForResult(authorization.pendingIntent!!.intentSender,
                                    requestCode, null, 0, 0, 0)
                            } catch (e: Exception) { fail("GOOGLE_LOGIN", e.message) }
                        }
                    } else complete(authorization)
                }.addOnFailureListener { fail("GOOGLE_LOGIN", it.message) }
            }
            if (oldToken.isNullOrBlank()) authorize()
            else Thread {
                try {
                    GoogleAuthUtil.clearToken(activity.applicationContext, oldToken)
                    activity.runOnUiThread { if (pending != null) authorize() }
                } catch (e: Exception) { activity.runOnUiThread { fail("GOOGLE_REFRESH", e.message) } }
            }.start()
        }
    }

    private fun complete(authorization: AuthorizationResult) {
        val token = authorization.accessToken
        if (token.isNullOrBlank()) { fail("GOOGLE_TOKEN", "Google 인증 토큰을 받지 못했습니다"); return }
        pending?.success(mapOf("accessToken" to token))
        pending = null
    }

    private fun fail(code: String, message: String?) {
        pending?.error(code, message ?: "Google Drive 로그인에 실패했습니다", null)
        pending = null
    }

    fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        if (resultCode != Activity.RESULT_OK || data == null) fail("CANCELLED", "Google 로그인이 취소되었습니다")
        else try { complete(client.getAuthorizationResultFromIntent(data)) }
        catch (e: Exception) { fail("GOOGLE_LOGIN", e.message) }
        return true
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        fail("CLOSED", "로그인 창이 닫혔습니다")
    }
}
