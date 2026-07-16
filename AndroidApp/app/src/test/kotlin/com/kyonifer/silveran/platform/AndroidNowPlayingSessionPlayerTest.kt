package com.kyonifer.silveran.platform

import android.os.Looper
import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class AndroidNowPlayingSessionPlayerTest {
    @Test
    fun publishesChapterStateAndForwardsCommands() {
        val commands = mutableListOf<ReceivedCommand>()
        val player = AndroidNowPlayingSessionPlayer(Looper.getMainLooper()) { token, command, value ->
            commands += ReceivedCommand(token, command, value)
        }
        player.configureCommands(commandConfiguration())
        player.update(snapshot())

        assertEquals(Player.STATE_READY, player.playbackState)
        assertEquals("The Book", player.currentMediaItem?.mediaMetadata?.title)
        assertEquals("Chapter 2", player.currentMediaItem?.mediaMetadata?.artist)
        assertEquals("The Author", player.currentMediaItem?.mediaMetadata?.albumTitle)
        assertEquals(120_000L, player.duration)
        assertEquals(12_500L, player.currentPosition)
        assertEquals(15_000L, player.seekForwardIncrement)
        assertEquals(10_000L, player.seekBackIncrement)
        assertEquals(1.25f, player.playbackParameters.speed)
        assertTrue(player.isCommandAvailable(Player.COMMAND_PLAY_PAUSE))
        assertTrue(player.isCommandAvailable(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM))
        assertTrue(player.isCommandAvailable(Player.COMMAND_SET_SPEED_AND_PITCH))
        assertFalse(player.isCommandAvailable(Player.COMMAND_SEEK_TO_NEXT))

        player.pause()
        assertFalse(player.playWhenReady)
        assertEquals(ReceivedCommand("commands", "pause", 0.0), commands.removeFirst())

        player.seekForward()
        assertEquals(ReceivedCommand("commands", "skipForward", 15.0), commands.removeFirst())

        player.seekTo(42_000L)
        assertEquals(
            ReceivedCommand("commands", "changePlaybackPosition", 42.0),
            commands.removeFirst(),
        )

        player.setPlaybackSpeed(1.5f)
        assertEquals(
            ReceivedCommand("commands", "changePlaybackRate", 1.5),
            commands.removeFirst(),
        )
    }

    @Test
    fun teardownAndClearRemainIndependentAndRejectStaleTokens() {
        val player = AndroidNowPlayingSessionPlayer(Looper.getMainLooper()) { _, _, _ -> }
        player.configureCommands(commandConfiguration())
        player.update(snapshot())

        player.teardownCommands("stale")
        assertTrue(player.isCommandAvailable(Player.COMMAND_PLAY_PAUSE))

        player.teardownCommands("commands")
        assertFalse(player.isCommandAvailable(Player.COMMAND_PLAY_PAUSE))
        assertEquals(Player.STATE_READY, player.playbackState)
        assertEquals("The Book", player.currentMediaItem?.mediaMetadata?.title)

        player.clear()
        assertEquals(Player.STATE_IDLE, player.playbackState)
        assertEquals(0, player.mediaItemCount)
    }

    @Test
    fun positionSeekingFollowsTheCommandConfiguration() {
        val player = AndroidNowPlayingSessionPlayer(Looper.getMainLooper()) { _, _, _ -> }
        player.configureCommands(
            commandConfiguration().copy(supportsChangePlaybackPosition = false),
        )
        player.update(snapshot())

        assertFalse(player.isCurrentMediaItemSeekable)
        assertFalse(player.isCommandAvailable(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM))
        assertTrue(player.isCommandAvailable(Player.COMMAND_SEEK_FORWARD))
    }

    private fun snapshot() = AndroidNowPlayingSnapshot(
        title = "The Book",
        artist = "Chapter 2",
        albumTitle = "The Author",
        durationSeconds = 120.0,
        elapsedSeconds = 12.5,
        playbackRate = 1.25,
        isPlaying = true,
        artwork = byteArrayOf(1, 2, 3),
    )

    private fun commandConfiguration() = AndroidNowPlayingCommandConfiguration(
        token = "commands",
        skipForwardSeconds = 15.0,
        skipBackwardSeconds = 10.0,
        supportsChangePlaybackPosition = true,
        supportsChangePlaybackRate = true,
    )

    private data class ReceivedCommand(
        val token: String,
        val command: String,
        val value: Double,
    )
}
