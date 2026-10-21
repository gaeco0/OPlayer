package com.oplayer.oplayer

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.ContextThemeWrapper
import androidx.mediarouter.app.MediaRouteChooserDialog
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaSeekOptions
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class CastBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "oplayer/cast")
    private val handler = Handler(Looper.getMainLooper())
    private var context: CastContext? = null
    private var pendingConnect: MethodChannel.Result? = null
    private var connecting = false
    private var chooser: MediaRouteChooserDialog? = null
    private val mediaCallback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() { channel.invokeMethod("status", status()) }
        override fun onMetadataUpdated() { channel.invokeMethod("status", status()) }
    }
    private val listener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarting(session: CastSession) { connecting = true }
        override fun onSessionStarted(session: CastSession, sessionId: String) { connected(session) }
        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) { connected(session) }
        override fun onSessionStartFailed(session: CastSession, error: Int) { failed(error) }
        override fun onSessionResumeFailed(session: CastSession, error: Int) { failed(error) }
        override fun onSessionEnded(session: CastSession, error: Int) { channel.invokeMethod("status", status()) }
        override fun onSessionSuspended(session: CastSession, reason: Int) { channel.invokeMethod("status", status()) }
        override fun onSessionEnding(session: CastSession) { }
        override fun onSessionResuming(session: CastSession, sessionId: String) { connecting = true }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "connect" -> connect(result)
                    "status" -> result.success(status())
                    "load" -> {
                        val client = ensure().sessionManager.currentCastSession?.remoteMediaClient
                            ?: throw IllegalStateException("먼저 Cast 기기에 연결해 주세요")
                        val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MOVIE).apply {
                            putString(MediaMetadata.KEY_TITLE, call.argument<String>("title") ?: "OPlayer")
                        }
                        val info = MediaInfo.Builder(call.argument<String>("url")!!)
                            .setContentType(call.argument<String>("mime") ?: "video/mp4")
                            .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED).setMetadata(metadata).build()
                        client.load(MediaLoadRequestData.Builder().setMediaInfo(info).setAutoplay(true)
                            .setCurrentTime(call.argument<Number>("position")?.toLong() ?: 0L).build())
                            .setResultCallback {
                                if (it.status.isSuccess) result.success(true)
                                else result.error("CAST_LOAD", "기기가 영상을 열지 못했습니다 (${it.status.statusCode})", null)
                            }
                    }
                    "play" -> { ensure().sessionManager.currentCastSession?.remoteMediaClient?.play(); result.success(null) }
                    "pause" -> { ensure().sessionManager.currentCastSession?.remoteMediaClient?.pause(); result.success(null) }
                    "seek" -> {
                        ensure().sessionManager.currentCastSession?.remoteMediaClient?.seek(MediaSeekOptions.Builder()
                            .setPosition(call.argument<Number>("position")?.toLong() ?: 0L).build())
                        result.success(null)
                    }
                    "volume" -> {
                        ensure().sessionManager.currentCastSession?.volume = (call.argument<Number>("value")?.toDouble() ?: 1.0).coerceIn(0.0, 1.0)
                        result.success(null)
                    }
                    "stop" -> { context?.sessionManager?.endCurrentSession(true); result.success(null) }
                    "systemOutput" -> { activity.startActivity(Intent(Settings.ACTION_CAST_SETTINGS)); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("CAST", e.message, null) }
        }
    }

    private fun ensure(): CastContext {
        context?.let { return it }
        return CastContext.getSharedInstance(activity).also {
            context = it
            it.sessionManager.addSessionManagerListener(listener, CastSession::class.java)
        }
    }

    private fun connect(result: MethodChannel.Result) {
        val ctx = ensure()
        val current = ctx.sessionManager.currentCastSession
        if (current?.isConnected == true) { result.success(status()); return }
        if (pendingConnect != null) { result.error("CAST_BUSY", "기기를 연결하는 중입니다", null); return }
        pendingConnect = result
        connecting = false
        chooser = MediaRouteChooserDialog(ContextThemeWrapper(activity, androidx.appcompat.R.style.Theme_AppCompat_Dialog)).apply {
            routeSelector = ctx.mergedSelector ?: throw IllegalStateException("Cast 기기 탐색을 시작할 수 없습니다")
            setOnDismissListener {
                handler.postDelayed({
                    if (!connecting && pendingConnect != null) { pendingConnect?.success(null); pendingConnect = null }
                }, 1500)
            }
            show()
        }
        handler.postDelayed({ if (pendingConnect != null) failed(-1) }, 120000)
    }

    private fun connected(session: CastSession) {
        connecting = false
        session.remoteMediaClient?.registerCallback(mediaCallback)
        pendingConnect?.success(status())
        pendingConnect = null
        chooser?.dismiss()
        channel.invokeMethod("status", status())
    }

    private fun failed(code: Int) {
        connecting = false
        pendingConnect?.error("CAST_CONNECT", "Cast 연결 실패 ($code)", null)
        pendingConnect = null
    }

    private fun status(): Map<String, Any?> {
        val session = context?.sessionManager?.currentCastSession
        val client = session?.remoteMediaClient
        return mapOf("connected" to (session?.isConnected == true), "name" to session?.castDevice?.friendlyName,
            "address" to session?.castDevice?.inetAddress?.hostAddress,
            "port" to session?.castDevice?.servicePort,
            "playing" to (client?.mediaStatus?.playerState == MediaStatus.PLAYER_STATE_PLAYING),
            "position" to (client?.approximateStreamPosition ?: 0L), "duration" to (client?.streamDuration ?: 0L))
    }

    fun dispose() {
        chooser?.dismiss()
        handler.removeCallbacksAndMessages(null)
        context?.sessionManager?.currentCastSession?.remoteMediaClient?.unregisterCallback(mediaCallback)
        context?.sessionManager?.removeSessionManagerListener(listener, CastSession::class.java)
        channel.setMethodCallHandler(null)
    }
}
