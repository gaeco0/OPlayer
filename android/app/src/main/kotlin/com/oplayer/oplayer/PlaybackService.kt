package com.oplayer.oplayer

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodChannel

class PlaybackService : Service() {
    companion object {
        var events: MethodChannel? = null
        var running = false
        private const val CHANNEL = "oplayer_playback"
        private const val NOTIFICATION = 7910
    }
    private lateinit var session: MediaSessionCompat
    private var foreground = false
    private var remote = false
    private var hasAudioFocus = false
    private var focusRequest: AudioFocusRequest? = null
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change < 0 && !remote) events?.invokeMethod("pause", null)
    }
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (!remote && intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) events?.invokeMethod("pause", null)
        }
    }

    override fun onCreate() {
        super.onCreate()
        running = true
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), Context.RECEIVER_NOT_EXPORTED)
        else @Suppress("DEPRECATION") registerReceiver(noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        session = MediaSessionCompat(this, "OPlayer").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() { events?.invokeMethod("play", null) }
                override fun onPause() { events?.invokeMethod("pause", null) }
                override fun onStop() { events?.invokeMethod("stop", null) }
                override fun onSkipToNext() { events?.invokeMethod("next", null) }
                override fun onSkipToPrevious() { events?.invokeMethod("previous", null) }
                override fun onSeekTo(pos: Long) { events?.invokeMethod("seek", pos) }
                override fun onRewind() { events?.invokeMethod("rewind", null) }
                override fun onFastForward() { events?.invokeMethod("forward", null) }
                override fun onCustomAction(action: String?, extras: android.os.Bundle?) {
                    if (action == "rewind" || action == "forward") events?.invokeMethod(action, null)
                }
            })
            isActive = true
        }
        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel(CHANNEL, "미디어 재생", NotificationManager.IMPORTANCE_LOW))
    }

    private fun command(name: String, id: Int): PendingIntent = PendingIntent.getService(this, id,
        Intent(this, PlaybackService::class.java).putExtra("command", name), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) { stopSelf(); return START_NOT_STICKY }
        intent.getStringExtra("command")?.let { events?.invokeMethod(it, null); return START_NOT_STICKY }
        val title = intent.getStringExtra("title") ?: "OPlayer"
        val subtitle = intent.getStringExtra("subtitle") ?: ""
        val playing = intent.getBooleanExtra("playing", false)
        remote = intent.getBooleanExtra("remote", false)
        val position = intent.getLongExtra("position", 0L)
        val duration = intent.getLongExtra("duration", 0L)
        session.setMetadata(MediaMetadataCompat.Builder().putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, subtitle).putLong(MediaMetadataCompat.METADATA_KEY_DURATION, duration).build())
        val visible = buildList {
            add("rewind"); add("forward")
            if (intent.getBooleanExtra("canPrevious", true)) add("previous")
            if (intent.getBooleanExtra("canNext", true)) add("next")
        }
        var supported = PlaybackStateCompat.ACTION_PLAY or PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or PlaybackStateCompat.ACTION_SEEK_TO or
            PlaybackStateCompat.ACTION_REWIND or PlaybackStateCompat.ACTION_FAST_FORWARD or PlaybackStateCompat.ACTION_STOP
        if ("previous" in visible) supported = supported or PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
        if ("next" in visible) supported = supported or PlaybackStateCompat.ACTION_SKIP_TO_NEXT
        val state = PlaybackStateCompat.Builder().setActions(supported)
            .setState(if (playing) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                position, if (playing) intent.getFloatExtra("rate", 1f) else 0f)
        for (action in visible.filter { it != "previous" && it != "next" }) {
            state.addCustomAction(action, playbackActionTitle(action, playing), playbackActionIcon(action, playing))
        }
        session.setPlaybackState(state.build())
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java)
            .putExtra("oplayer_open_player", true)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        session.setSessionActivity(open)
        val displayed = visible.toMutableList().apply { add(minOf(1, size), "playPause") }
        val builder = NotificationCompat.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_stat_playback)
            .setContentTitle(title).setContentText(subtitle).setContentIntent(open).setOnlyAlertOnce(true).setOngoing(playing)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setDeleteIntent(command("stop", 4))
        for (action in displayed) {
            val name = if (action == "playPause") { if (playing) "pause" else "play" } else action
            builder.addAction(playbackActionIcon(action, playing), playbackActionTitle(action, playing), command(name, name.hashCode()))
        }
        val notification = builder.setStyle(androidx.media.app.NotificationCompat.MediaStyle()
            .setMediaSession(session.sessionToken).setShowActionsInCompactView(*displayed.indices.take(3).toIntArray())).build()
        if (intent.getBooleanExtra("foreground", false)) { startForeground(NOTIFICATION, notification); foreground = true }
        else {
            if (foreground) { stopForeground(STOP_FOREGROUND_DETACH); foreground = false }
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification)
        }
        // Android 15+ grants background audio focus only to a foreground service.
        updateAudioFocus(playing && !remote)
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) { events?.invokeMethod("stop", null); stopSelf(); super.onTaskRemoved(rootIntent) }
    override fun onBind(intent: Intent?): IBinder? = null
    private fun updateAudioFocus(wanted: Boolean) {
        if (wanted == hasAudioFocus) return
        val manager = getSystemService(AudioManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            if (wanted) {
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
                    .setOnAudioFocusChangeListener(focusListener).build()
                focusRequest = request
                hasAudioFocus = manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            } else { focusRequest?.let { manager.abandonAudioFocusRequest(it) }; hasAudioFocus = false }
        } else {
            @Suppress("DEPRECATION")
            if (wanted) hasAudioFocus = manager.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            else { manager.abandonAudioFocus(focusListener); hasAudioFocus = false }
        }
        if (wanted && !hasAudioFocus) events?.invokeMethod("pause", null)
    }
    override fun onDestroy() {
        unregisterReceiver(noisyReceiver)
        updateAudioFocus(false)
        session.isActive = false
        session.release()
        if (foreground) stopForeground(STOP_FOREGROUND_REMOVE)
        getSystemService(NotificationManager::class.java).cancel(NOTIFICATION)
        running = false
        super.onDestroy()
    }
}
