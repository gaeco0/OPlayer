package com.oplayer.oplayer

/** Keep every command reachable even when System UI only permits three PiP actions. */
fun playbackActionPage(commands: List<String>, capacity: Int, page: Int): List<String> {
    if (capacity <= 0) return emptyList()
    if (commands.size <= capacity) return commands
    if (capacity == 1) return listOf("playPause")
    val pages = commands.chunked(capacity - 1)
    return pages[Math.floorMod(page, pages.size)] + "more"
}

fun playbackActionIcon(command: String, playing: Boolean): Int = when (command) {
    "rewind" -> R.drawable.ic_replay_10
    "forward" -> R.drawable.ic_forward_10
    "audioOnly" -> R.drawable.ic_headphones
    "previous" -> android.R.drawable.ic_media_previous
    "next" -> android.R.drawable.ic_media_next
    "stop" -> android.R.drawable.ic_menu_close_clear_cancel
    "more" -> R.drawable.ic_playback_more
    else -> if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
}

fun playbackActionTitle(command: String, playing: Boolean): String = when (command) {
    "rewind" -> "10초 뒤로"
    "forward" -> "10초 앞으로"
    "audioOnly" -> "소리만 재생"
    "previous" -> "이전 파일"
    "next" -> "다음 파일"
    "stop" -> "재생 종료"
    "more" -> "더보기 · 다음 조작 묶음"
    else -> if (playing) "일시정지" else "재생"
}
