package com.oplayer.oplayer

import android.os.Handler
import android.os.Looper
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/** Exports public trust anchors from the app's existing Network Security Config.
 * No private keys, trust-all manager, hostname override or certificate callback.
 */
class NetworkTrustBridge(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "oplayer/network-trust")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var disposed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "certificates") {
                result.notImplemented()
            } else {
                worker.execute {
                    try {
                        // The platform default honors network_security_config's
                        // system + user anchors, including disabled CA handling.
                        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
                        factory.init(null as KeyStore?)
                        val manager = factory.trustManagers.filterIsInstance<X509TrustManager>().first()
                        val pem = manager.acceptedIssuers.joinToString("\n") { certificate ->
                            "-----BEGIN CERTIFICATE-----\n" +
                                Base64.encodeToString(certificate.encoded, Base64.NO_WRAP).chunked(64).joinToString("\n") +
                                "\n-----END CERTIFICATE-----\n"
                        }
                        check(pem.isNotBlank()) { "Android trust store is empty" }
                        main.post { if (!disposed) result.success(pem) }
                    } catch (e: Exception) {
                        main.post { if (!disposed) result.error("TRUST_STORE", e.message, null) }
                    }
                }
            }
        }
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
