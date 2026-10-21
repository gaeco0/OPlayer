package com.oplayer.oplayer

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.graphics.drawable.Icon

fun pipSeekIcon(seconds: Int, forward: Boolean): Icon {
    val bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; strokeWidth = 7f; style = Paint.Style.STROKE }
    canvas.save()
    if (forward) canvas.scale(-1f, 1f, 48f, 48f)
    canvas.drawArc(12f, 15f, 84f, 87f, -85f, 290f, false, paint)
    paint.style = Paint.Style.FILL
    canvas.drawPath(Path().apply { moveTo(49f, 3f); lineTo(49f, 31f); lineTo(30f, 17f); close() }, paint)
    canvas.restore()
    paint.apply { textSize = if (seconds < 100) 33f else 26f; textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD }
    canvas.drawText(seconds.toString(), 48f, 65f, paint)
    return Icon.createWithBitmap(bitmap)
}

fun playbackActionIcon(command: String, playing: Boolean): Int = when (command) {
    "rewind" -> R.drawable.ic_replay_10
    "forward" -> R.drawable.ic_forward_10
    "previous" -> android.R.drawable.ic_media_previous
    "next" -> android.R.drawable.ic_media_next
    else -> if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
}

fun playbackActionTitle(command: String, playing: Boolean): String = when (command) {
    "rewind" -> "10초 뒤로"
    "forward" -> "10초 앞으로"
    "previous" -> "이전 파일"
    "next" -> "다음 파일"
    else -> if (playing) "일시정지" else "재생"
}
