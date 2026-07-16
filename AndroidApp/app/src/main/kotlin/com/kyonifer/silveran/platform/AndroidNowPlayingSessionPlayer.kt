package com.kyonifer.silveran.platform

import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

internal data class AndroidNowPlayingSnapshot(
    val title: String,
    val artist: String?,
    val albumTitle: String?,
    val durationSeconds: Double?,
    val elapsedSeconds: Double?,
    val playbackRate: Double,
    val isPlaying: Boolean,
    val artwork: ByteArray?,
)

internal data class AndroidNowPlayingCommandConfiguration(
    val token: String,
    val skipForwardSeconds: Double,
    val skipBackwardSeconds: Double,
    val supportsChangePlaybackPosition: Boolean,
    val supportsChangePlaybackRate: Boolean,
)

internal fun interface AndroidNowPlayingCommandSink {
    fun send(token: String, command: String, value: Double)
}

/**
 * Kotlin/Media3 backend for AndroidNowPlayingPresenter, the Swift implementation
 * of SilveranKit's NowPlayingPresenting protocol.
 *
 * Mirrors now-playing state into a Player for a future MediaLibrarySession and
 * routes its commands back to the Swift playback actor. Audio transport remains
 * owned by AndroidAudioPlayer and its ExoPlayer backend.
 */
@OptIn(UnstableApi::class)
internal class AndroidNowPlayingSessionPlayer(
    looper: Looper,
    private val commandSink: AndroidNowPlayingCommandSink,
) : SimpleBasePlayer(looper) {
    private var snapshot: AndroidNowPlayingSnapshot? = null
    private var commandConfiguration: AndroidNowPlayingCommandConfiguration? = null

    fun update(snapshot: AndroidNowPlayingSnapshot) {
        requireApplicationThread()
        this.snapshot = snapshot
        invalidateState()
    }

    fun clear() {
        requireApplicationThread()
        snapshot = null
        invalidateState()
    }

    fun configureCommands(configuration: AndroidNowPlayingCommandConfiguration) {
        requireApplicationThread()
        commandConfiguration = configuration
        invalidateState()
    }

    fun teardownCommands(token: String) {
        requireApplicationThread()
        if (commandConfiguration?.token != token) return
        commandConfiguration = null
        invalidateState()
    }

    override fun getState(): State {
        requireApplicationThread()
        val snapshot = snapshot
        val configuration = commandConfiguration
        val commands = availableCommands(snapshot != null, configuration)

        if (snapshot == null) {
            return State.Builder()
                .setAvailableCommands(commands)
                .setPlaybackState(Player.STATE_IDLE)
                .setPlayWhenReady(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
                .build()
        }

        val metadataBuilder = MediaMetadata.Builder()
            .setTitle(snapshot.title)
            .setArtist(snapshot.artist)
            .setAlbumTitle(snapshot.albumTitle)
            .setIsPlayable(true)
            .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK_CHAPTER)
        snapshot.artwork?.let {
            metadataBuilder.setArtworkData(it, MediaMetadata.PICTURE_TYPE_FRONT_COVER)
        }
        val metadata = metadataBuilder.build()
        val mediaItem = MediaItem.Builder()
            .setMediaId(NOW_PLAYING_MEDIA_ID)
            .setMediaMetadata(metadata)
            .build()
        val durationUs = snapshot.durationSeconds.secondsToMicrosecondsOrUnset()
        val mediaItemData = MediaItemData.Builder(NOW_PLAYING_MEDIA_ID)
            .setMediaItem(mediaItem)
            .setMediaMetadata(metadata)
            .setDurationUs(durationUs)
            .setIsSeekable(configuration?.supportsChangePlaybackPosition == true)
            .build()

        return State.Builder()
            .setAvailableCommands(commands)
            .setPlaylist(listOf(mediaItemData))
            .setCurrentMediaItemIndex(0)
            .setContentPositionMs(snapshot.elapsedSeconds.secondsToMilliseconds())
            .setPlaybackParameters(PlaybackParameters(snapshot.normalizedRate().toFloat()))
            .setPlaybackState(Player.STATE_READY)
            .setPlayWhenReady(
                snapshot.isPlaying,
                Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST,
            )
            .setSeekForwardIncrementMs(configuration?.skipForwardSeconds.secondsToMilliseconds())
            .setSeekBackIncrementMs(configuration?.skipBackwardSeconds.secondsToMilliseconds())
            .build()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<Any> {
        val configuration = commandConfiguration ?: return immediateVoidFuture()
        snapshot = snapshot?.copy(isPlaying = playWhenReady)
        commandSink.send(
            configuration.token,
            if (playWhenReady) COMMAND_PLAY else COMMAND_PAUSE,
            0.0,
        )
        return immediateVoidFuture()
    }

    override fun handleSeek(
        mediaItemIndex: Int,
        positionMs: Long,
        seekCommand: Int,
    ): ListenableFuture<Any> {
        val configuration = commandConfiguration ?: return immediateVoidFuture()
        snapshot = snapshot?.copy(elapsedSeconds = positionMs.coerceAtLeast(0L) / 1_000.0)

        when (seekCommand) {
            Player.COMMAND_SEEK_BACK -> commandSink.send(
                configuration.token,
                COMMAND_SKIP_BACKWARD,
                configuration.skipBackwardSeconds,
            )
            Player.COMMAND_SEEK_FORWARD -> commandSink.send(
                configuration.token,
                COMMAND_SKIP_FORWARD,
                configuration.skipForwardSeconds,
            )
            Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM -> commandSink.send(
                configuration.token,
                COMMAND_CHANGE_POSITION,
                positionMs.coerceAtLeast(0L) / 1_000.0,
            )
        }
        return immediateVoidFuture()
    }

    override fun handleSetPlaybackParameters(
        playbackParameters: PlaybackParameters,
    ): ListenableFuture<Any> {
        val configuration = commandConfiguration ?: return immediateVoidFuture()
        snapshot = snapshot?.copy(playbackRate = playbackParameters.speed.toDouble())
        commandSink.send(
            configuration.token,
            COMMAND_CHANGE_RATE,
            playbackParameters.speed.toDouble(),
        )
        return immediateVoidFuture()
    }

    private fun availableCommands(
        hasSnapshot: Boolean,
        configuration: AndroidNowPlayingCommandConfiguration?,
    ): Player.Commands {
        val commands = Player.Commands.Builder()
            .add(Player.COMMAND_GET_CURRENT_MEDIA_ITEM)
            .add(Player.COMMAND_GET_METADATA)
            .add(Player.COMMAND_GET_TIMELINE)

        if (hasSnapshot && configuration != null) {
            commands
                .add(Player.COMMAND_PLAY_PAUSE)
                .add(Player.COMMAND_SEEK_BACK)
                .add(Player.COMMAND_SEEK_FORWARD)
            if (configuration.supportsChangePlaybackPosition) {
                commands.add(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
            }
            if (configuration.supportsChangePlaybackRate) {
                commands.add(Player.COMMAND_SET_SPEED_AND_PITCH)
            }
        }
        return commands.build()
    }

    private fun requireApplicationThread() {
        check(Looper.myLooper() == applicationLooper) {
            "AndroidNowPlayingSessionPlayer must be accessed on its application looper"
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun immediateVoidFuture(): ListenableFuture<Any> =
        Futures.immediateVoidFuture() as ListenableFuture<Any>

    companion object {
        private const val NOW_PLAYING_MEDIA_ID = "silveran-now-playing"

        const val COMMAND_PLAY = "play"
        const val COMMAND_PAUSE = "pause"
        const val COMMAND_SKIP_FORWARD = "skipForward"
        const val COMMAND_SKIP_BACKWARD = "skipBackward"
        const val COMMAND_CHANGE_POSITION = "changePlaybackPosition"
        const val COMMAND_CHANGE_RATE = "changePlaybackRate"
    }
}

private fun AndroidNowPlayingSnapshot.normalizedRate(): Double =
    playbackRate.takeIf { it.isFinite() && it > 0.0 } ?: 1.0

private fun Double?.secondsToMilliseconds(): Long =
    this?.takeIf { it.isFinite() }?.coerceAtLeast(0.0)?.times(1_000.0)?.toLong() ?: 0L

private fun Double?.secondsToMicrosecondsOrUnset(): Long =
    this?.takeIf { it.isFinite() && it >= 0.0 }?.times(C.MICROS_PER_SECOND)?.toLong()
        ?: C.TIME_UNSET
