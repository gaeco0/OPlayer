package com.oplayer.oplayer

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.widget.Toast
import android.Manifest
import android.util.Rational
import io.flutter.plugin.common.MethodChannel
import androidx.annotation.ChecksSdkIntAtLeast
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import androidx.core.app.ActivityCompat
import com.arthenica.ffmpegkit.FFmpegKit
import com.arthenica.ffmpegkit.FFmpegKitConfig

class MainActivity : FlutterActivity() {
    private lateinit var pipChannel: MethodChannel
    private lateinit var mediaChannel: MethodChannel
    private var castBridge: CastBridge? = null
    private var privacyBridge: PrivacyBridge? = null
    private var byeDpiPid: Int? = null
    private lateinit var downloadChannel: MethodChannel
    private var notificationRequested = false
    private var exitBackAt: Long? = null
    private var exitToast: Toast? = null
    private var playerActive = false
    private var playing = false
    private var pipActionsPage = 0
    private var canPrevious = false
    private var canNext = false
    private var aspect = 16.0 / 9.0
    private var receiverRegistered = false
    private val toggleAction = "com.oplayer.oplayer.PIP_TOGGLE"
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != toggleAction || !playerActive) return
            val command = intent.getStringExtra("command") ?: "playPause"
            if (command == "more") {
                pipActionsPage++
                if (supportsPip()) setPictureInPictureParams(pipParams())
            } else if (command in listOf("rewind", "forward", "playPause", "audioOnly", "previous", "next")) {
                pipChannel.invokeMethod(command, null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        privacyBridge = PrivacyBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        downloadChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oplayer/downloads")
        DownloadService.events = downloadChannel
        downloadChannel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "consumeOpen" -> {
                        val pending = DownloadService.openPending
                        DownloadService.openPending = false
                        result.success(pending)
                    }
                    "finished" -> {
                        DownloadService.completed(this, call.argument<String>("id") ?: "",
                            call.argument<String>("name") ?: "", call.argument<Boolean>("success") == true)
                        result.success(null)
                    }
                    "update" -> {
                        if (call.argument<Boolean>("active") != true) {
                            stopService(Intent(this, DownloadService::class.java))
                            result.success(null)
                        } else {
                            val intent = Intent(this, DownloadService::class.java)
                                .putExtra("title", call.argument<String>("title"))
                                .putExtra("name", call.argument<String>("name"))
                                .putExtra("phase", call.argument<String>("phase"))
                                .putExtra("progress", call.argument<Number>("progress")?.toInt() ?: -1)
                            if (!DownloadService.running) {
                                DownloadService.pendingStart = result
                                ContextCompat.startForegroundService(this, intent)
                            } else {
                                startService(intent)
                                result.success(null)
                            }
                            if (Build.VERSION.SDK_INT >= 33 && !notificationRequested &&
                                ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                notificationRequested = true
                                ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7921)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                if (DownloadService.pendingStart === result) DownloadService.pendingStart = null
                result.error("DOWNLOAD_SERVICE", e.message, null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oplayer/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    "ownProcess" -> { byeDpiPid = call.arguments as? Int; result.success(null) }
                    "forgetProcess" -> { byeDpiPid = null; result.success(null) }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oplayer/ffmpeg")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "version" -> result.success(FFmpegKitConfig.getFFmpegVersion())
                        "execute" -> {
                            val args = call.argument<List<String>>("arguments")
                            if (args == null || args.isEmpty()) {
                                result.error("ARGUMENTS", "FFmpeg arguments are required", null)
                            } else {
                                FFmpegKit.executeWithArgumentsAsync(args.toTypedArray()) { session ->
                                    val response = mapOf(
                                        "code" to (session.returnCode?.value ?: -1),
                                        "error" to (session.allLogsAsString ?: session.failStackTrace ?: "")
                                    )
                                    runOnUiThread { result.success(response) }
                                }
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("FFMPEG", e.message, null)
                } catch (e: LinkageError) {
                    result.error("FFMPEG_LOAD", e.message, null)
                }
            }
        castBridge = CastBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        mediaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oplayer/media")
        PlaybackService.events = mediaChannel
        mediaChannel.setMethodCallHandler { call, result ->
            if (call.method != "update") { result.notImplemented(); return@setMethodCallHandler }
            try {
                if (call.argument<Boolean>("enabled") != true) {
                    stopService(Intent(this, PlaybackService::class.java))
                } else {
                    val intent = Intent(this, PlaybackService::class.java)
                        .putExtra("title", call.argument<String>("title") ?: "OPlayer")
                        .putExtra("subtitle", call.argument<String>("subtitle") ?: "")
                        .putExtra("playing", call.argument<Boolean>("playing") ?: false)
                        .putExtra("foreground", call.argument<Boolean>("foreground") ?: false)
                        .putExtra("remote", call.argument<Boolean>("remote") ?: false)
                        .putExtra("canAudioOnly", call.argument<Boolean>("canAudioOnly") ?: false)
                        .putExtra("canPrevious", call.argument<Boolean>("canPrevious") ?: false)
                        .putExtra("canNext", call.argument<Boolean>("canNext") ?: false)
                        .putExtra("position", call.argument<Number>("position")?.toLong() ?: 0L)
                        .putExtra("duration", call.argument<Number>("duration")?.toLong() ?: 0L)
                        .putExtra("rate", call.argument<Number>("rate")?.toFloat() ?: 1f)
                    if (call.argument<Boolean>("foreground") == true && !PlaybackService.running) ContextCompat.startForegroundService(this, intent)
                    else startService(intent)
                }
                result.success(null)
            } catch (e: Exception) { result.error("MEDIA_SESSION", e.message, null) }
        }
        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oplayer/pip")
        pipChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(supportsPip())
                "background" -> { moveTaskToBack(true); result.success(null) }
                "update" -> {
                    if (!playerActive) pipActionsPage = 0
                    playerActive = call.argument<Boolean>("active") ?: false
                    playing = call.argument<Boolean>("playing") ?: false
                    canPrevious = call.argument<Boolean>("canPrevious") ?: false
                    canNext = call.argument<Boolean>("canNext") ?: false
                    aspect = (call.argument<Number>("aspect")?.toDouble() ?: aspect).coerceIn(0.42, 2.39)
                    if (supportsPip()) setPictureInPictureParams(pipParams())
                    result.success(null)
                }
                "enter" -> {
                    try {
                        result.success(supportsPip() && playerActive && enterPictureInPictureMode(pipParams()))
                    } catch (e: IllegalStateException) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
        if (!receiverRegistered) {
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, IntentFilter(toggleAction), Context.RECEIVER_NOT_EXPORTED)
            else @Suppress("DEPRECATION") registerReceiver(receiver, IntentFilter(toggleAction))
            receiverRegistered = true
        }
    }

    @ChecksSdkIntAtLeast(api = 26)
    private fun supportsPip() = Build.VERSION.SDK_INT >= 26 &&
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    @RequiresApi(26)
    private fun pipParams(): PictureInPictureParams {
        val commands = playbackActionPage(
            listOf("rewind", "forward", "playPause", "audioOnly", "previous", "next"),
            maxNumPictureInPictureActions, pipActionsPage)
        val actions = commands.map { command ->
            val intent = Intent(toggleAction).setPackage(packageName).putExtra("command", command)
            val pending = PendingIntent.getBroadcast(this, command.hashCode(), intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val title = playbackActionTitle(command, playing)
            RemoteAction(Icon.createWithResource(this, playbackActionIcon(command, playing)), title, title, pending).apply {
                isEnabled = when (command) { "previous" -> canPrevious; "next" -> canNext; else -> true }
            }
        }
        val rect = Rect()
        window.decorView.getGlobalVisibleRect(rect)
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational((aspect * 1000).toInt(), 1000))
            .setActions(actions)
        if (!rect.isEmpty) builder.setSourceRectHint(rect)
        if (Build.VERSION.SDK_INT >= 31) builder.setAutoEnterEnabled(playerActive && playing)
        return builder.build()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT in 26..30 && supportsPip() && playerActive && playing) {
            try { enterPictureInPictureMode(pipParams()) } catch (_: IllegalStateException) { }
        }
    }

    @RequiresApi(26)
    override fun onPictureInPictureModeChanged(active: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(active, newConfig)
        pipChannel.invokeMethod("changed", active)
    }

    // Keep Android 13+ root back gestures in Flutter so they also reach the
    // exit guard below. Flutter still handles page, folder and browser history.
    override fun setFrameworkHandlesBack(frameworkHandlesBack: Boolean) {
        super.setFrameworkHandlesBack(true)
    }

    override fun popSystemNavigator(): Boolean {
        val now = SystemClock.elapsedRealtime()
        val previous = exitBackAt
        if (previous != null && now - previous <= 2000L) {
            exitBackAt = null
            exitToast?.cancel()
            finish()
        } else {
            exitBackAt = now
            exitToast?.cancel()
            exitToast = Toast.makeText(this, "뒤로 버튼을 한 번 더 누르면 종료됩니다", Toast.LENGTH_SHORT)
            exitToast?.show()
        }
        return true
    }

    override fun onStop() {
        privacyBridge?.cancel()
        exitBackAt = null
        exitToast?.cancel()
        super.onStop()
        if (playerActive) {
            pipChannel.invokeMethod("backgrounded", null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra(DownloadService.OPEN, false) && ::downloadChannel.isInitialized) {
            downloadChannel.invokeMethod("open", null)
        }
        if (intent.getBooleanExtra("oplayer_open_player", false) && ::mediaChannel.isInitialized) {
            mediaChannel.invokeMethod("open", null)
        }
    }

    override fun onDestroy() {
        privacyBridge?.dispose()
        DownloadService.events = null
        stopService(Intent(this, DownloadService::class.java))
        byeDpiPid?.let { android.os.Process.killProcess(it) }
        byeDpiPid = null
        if (receiverRegistered) unregisterReceiver(receiver)
        castBridge?.dispose()
        PlaybackService.events = null
        stopService(Intent(this, PlaybackService::class.java))
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val privacy = getSharedPreferences("oplayer_privacy", 0)
        if (privacy.getBoolean("preventCapture", false) || privacy.getBoolean("appLock", false)) {
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        }
        if (intent.getBooleanExtra(DownloadService.OPEN, false)) DownloadService.openPending = true
        super.onCreate(savedInstanceState)
    }
}
