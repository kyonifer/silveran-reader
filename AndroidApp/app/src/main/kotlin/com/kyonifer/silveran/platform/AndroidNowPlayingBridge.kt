package com.kyonifer.silveran.platform

import android.os.Handler
import android.os.Looper
import android.util.Base64
import androidx.annotation.Keep
import androidx.media3.common.Player
import com.kyonifer.silveran.bridge.SilveranAndroidBridge

/** Static primitive-only surface consumed by AndroidNowPlayingPresenter in Swift. */
@Keep
object AndroidNowPlayingBridge {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var artwork: ByteArray? = null
    private var player: AndroidNowPlayingSessionPlayer? = null

    /** Player to pass to a future MediaLibrarySession.Builder. */
    fun sessionPlayer(): Player {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "The MediaLibrarySession player must be created on the main looper"
        }
        return player()
    }

    @JvmStatic
    fun update(
        title: String,
        artist: String,
        albumTitle: String,
        durationSeconds: Double,
        elapsedSeconds: Double,
        playbackRate: Double,
        isPlaying: Boolean,
        artworkBase64: String,
        artworkChanged: Boolean,
    ) = onMain {
        if (artworkChanged) {
            artwork = artworkBase64.takeIf(String::isNotEmpty)?.let {
                Base64.decode(it, Base64.DEFAULT)
            }
        }
        player().update(
            AndroidNowPlayingSnapshot(
                title = title,
                artist = artist.takeIf(String::isNotEmpty),
                albumTitle = albumTitle.takeIf(String::isNotEmpty),
                durationSeconds = durationSeconds.takeIf { it >= 0.0 && it.isFinite() },
                elapsedSeconds = elapsedSeconds.takeIf { it >= 0.0 && it.isFinite() },
                playbackRate = playbackRate,
                isPlaying = isPlaying,
                artwork = artwork,
            ),
        )
    }

    @JvmStatic
    fun clear() = onMain {
        artwork = null
        player().clear()
    }

    @JvmStatic
    fun configureCommands(
        token: String,
        skipForwardSeconds: Double,
        skipBackwardSeconds: Double,
        supportsChangePlaybackPosition: Boolean,
        supportsChangePlaybackRate: Boolean,
    ) = onMain {
        player().configureCommands(
            AndroidNowPlayingCommandConfiguration(
                token = token,
                skipForwardSeconds = skipForwardSeconds.nonnegativeOrZero(),
                skipBackwardSeconds = skipBackwardSeconds.nonnegativeOrZero(),
                supportsChangePlaybackPosition = supportsChangePlaybackPosition,
                supportsChangePlaybackRate = supportsChangePlaybackRate,
            ),
        )
    }

    @JvmStatic
    fun teardownCommands(token: String) = onMain {
        player().teardownCommands(token)
    }

    private fun player(): AndroidNowPlayingSessionPlayer = player ?: AndroidNowPlayingSessionPlayer(
        Looper.getMainLooper(),
        AndroidNowPlayingCommandSink { token, command, value ->
            SilveranAndroidBridge.androidNowPlayingCommand(token, command, value)
        },
    ).also { player = it }

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action()
        } else {
            mainHandler.post(action)
        }
    }
}

private fun Double.nonnegativeOrZero(): Double =
    takeIf { it.isFinite() }?.coerceAtLeast(0.0) ?: 0.0
