package com.oplayer.oplayer

import org.junit.Assert.*
import org.junit.Test

class PlaybackActionsTest {
    @Test fun pipPagesReachEveryCommandAndWrapWithinSystemLimit() {
        val commands = listOf("rewind", "forward", "playPause", "audioOnly", "previous", "next")
        val pages = (0..2).map { playbackActionPage(commands, 3, it) }
        assertEquals(listOf("rewind", "forward", "more"), pages[0])
        assertEquals(listOf("playPause", "audioOnly", "more"), pages[1])
        assertEquals(listOf("previous", "next", "more"), pages[2])
        assertEquals(commands.toSet(), pages.flatten().filter { it != "more" }.toSet())
        assertEquals(pages[0], playbackActionPage(commands, 3, 3))
        assertEquals(commands, playbackActionPage(commands, 6, 0))
        assertTrue(playbackActionPage(commands, 0, 0).isEmpty())
    }

    @Test fun mediaPagesReservePlayPauseSlotAndKeepStopAvailable() {
        val commands = listOf("rewind", "forward", "audioOnly", "previous", "next", "stop")
        assertEquals(listOf("rewind", "forward", "audioOnly", "more"), playbackActionPage(commands, 4, 0))
        assertEquals(listOf("previous", "next", "stop", "more"), playbackActionPage(commands, 4, 1))
    }
}
