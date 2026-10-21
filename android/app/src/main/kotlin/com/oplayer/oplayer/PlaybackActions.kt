package com.oplayer.oplayer

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
