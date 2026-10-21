package com.oplayer.oplayer

import android.app.Activity
import android.app.AlertDialog
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.hardware.fingerprint.FingerprintManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class PrivacyBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private var cancellation: CancellationSignal? = null
    private var pending: MethodChannel.Result? = null
    private var shielded = false
    private var storageFailed = false
    private var fingerprintDialog: AlertDialog? = null
    private val channel = MethodChannel(messenger, "oplayer/privacy")
    private val hashWorker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "deriveLockHash" -> {
                    val value = call.argument<String>("value")
                    val salt = call.argument<ByteArray>("salt")
                    if (value == null || value.length > 64 || value.any { it.code > 127 } || salt?.size != 32) {
                        result.error("ARGUMENT", "Invalid credential parameters", null)
                    } else if (Build.VERSION.SDK_INT < 26) {
                        result.notImplemented()
                    } else {
                        hashWorker.execute {
                            val spec = PBEKeySpec(value.toCharArray(), salt, 210000, 256)
                            try {
                                val hash = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
                                mainHandler.post { result.success(hash) }
                            } catch (_: Exception) {
                                mainHandler.post { result.error("HASH", "Credential verification failed", null) }
                            } finally { spec.clearPassword() }
                        }
                    }
                }
                "getCaptureProtection" -> result.success(activity.getSharedPreferences("oplayer_privacy", 0)
                    .getBoolean("preventCapture", false))
                "setCaptureProtection" -> {
                    val enabled = call.arguments == true
                    if (enabled) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    val saved = activity.getSharedPreferences("oplayer_privacy", 0).edit()
                        .putBoolean("preventCapture", enabled).commit()
                    if (saved) { applyProtection(); result.success(null) }
                    else {
                        storageFailed = true
                        applyProtection()
                        result.error("PRIVACY_STORAGE", "보호 설정을 저장하지 못했습니다", null)
                    }
                }
                "setLockPolicy" -> {
                    val appLock = call.argument<Boolean>("appLock") == true
                    val cover = call.argument<Boolean>("shielded") == true
                    // Force protection before persisting an enabled policy.
                    if (appLock || cover) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    val prefs = activity.getSharedPreferences("oplayer_privacy", 0)
                    val saved = prefs.getBoolean("appLock", false) == appLock ||
                        prefs.edit().putBoolean("appLock", appLock).commit()
                    if (saved) {
                        shielded = cover
                        applyProtection()
                        result.success(null)
                    } else {
                        storageFailed = true
                        applyProtection()
                        result.error("PRIVACY_STORAGE", "앱 잠금 보호 설정을 저장하지 못했습니다", null)
                    }
                }
                "biometricAvailable" -> result.success(available())
                "authenticate" -> authenticate(result)
                "cancelAuthentication" -> { cancel(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }
    private fun applyProtection() {
        val prefs = activity.getSharedPreferences("oplayer_privacy", 0)
        val secure = storageFailed || shielded || prefs.getBoolean("appLock", false) ||
            prefs.getBoolean("preventCapture", false)
        if (secure) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
    @Suppress("DEPRECATION")
    private fun available(): Boolean {
        return when {
            Build.VERSION.SDK_INT >= 30 -> activity.getSystemService(BiometricManager::class.java)
                ?.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK) == BiometricManager.BIOMETRIC_SUCCESS
            Build.VERSION.SDK_INT >= 29 -> activity.getSystemService(BiometricManager::class.java)
                ?.canAuthenticate() == BiometricManager.BIOMETRIC_SUCCESS
            Build.VERSION.SDK_INT >= 24 -> activity.getSystemService(FingerprintManager::class.java)
                ?.let { it.isHardwareDetected && it.hasEnrolledFingerprints() } == true
            else -> false
        }
    }
    private fun authenticate(result: MethodChannel.Result) {
        if (!available() || pending != null) {
            result.success(false)
            return
        }
        pending = result
        val signal = CancellationSignal()
        cancellation = signal
        try {
            if (Build.VERSION.SDK_INT < 28) {
                authenticateFingerprint(signal)
                return
            }
            val builder = BiometricPrompt.Builder(activity)
                .setTitle("OPlayer 잠금 해제")
                .setSubtitle("등록된 지문 또는 생체정보로 인증하세요")
                .setNegativeButton("PIN 또는 패턴 사용", activity.mainExecutor) { _, _ -> complete(false, signal) }
            if (Build.VERSION.SDK_INT >= 30) builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
            builder.build().authenticate(signal, activity.mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) { complete(true, signal) }
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) { complete(false, signal) }
            })
        } catch (_: Exception) { complete(false, signal) }
    }
    @Suppress("DEPRECATION")
    private fun authenticateFingerprint(signal: CancellationSignal) {
        fingerprintDialog = AlertDialog.Builder(activity)
            .setTitle("OPlayer 지문 인증")
            .setMessage("지문 센서에 손가락을 대세요")
            .setNegativeButton("PIN 또는 패턴 사용") { _, _ ->
                if (cancellation === signal) { signal.cancel(); complete(false, signal) }
            }.setOnCancelListener {
                if (cancellation === signal) { signal.cancel(); complete(false, signal) }
            }.show()
        activity.getSystemService(FingerprintManager::class.java).authenticate(null, signal, 0,
            object : FingerprintManager.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: FingerprintManager.AuthenticationResult) { complete(true, signal) }
                override fun onAuthenticationError(code: Int, message: CharSequence) { complete(false, signal) }
                override fun onAuthenticationFailed() { fingerprintDialog?.setMessage("인식하지 못했습니다. 지문을 다시 대세요.") }
            }, null)
    }
    private fun complete(success: Boolean, signal: CancellationSignal) {
        if (cancellation !== signal) return
        val result = pending
        pending = null
        cancellation = null
        fingerprintDialog?.dismiss()
        fingerprintDialog = null
        result?.success(success)
    }
    fun cancel() {
        val signal = cancellation ?: return
        signal.cancel()
        complete(false, signal)
    }
    fun dispose() { cancel(); hashWorker.shutdown(); channel.setMethodCallHandler(null) }
}
