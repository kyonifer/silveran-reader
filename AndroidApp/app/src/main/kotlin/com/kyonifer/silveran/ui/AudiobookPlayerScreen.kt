package com.kyonifer.silveran.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.media3.common.C
import androidx.media3.common.Player
import com.kyonifer.silveran.model.Book
import java.util.Locale
import kotlinx.coroutines.delay

@Composable
internal fun AudiobookPlayerScreen(
    book: Book,
    loading: Boolean,
    player: Player,
    modifier: Modifier,
) {
    var uiState by remember(book.id, player) {
        mutableStateOf(player.audiobookUiState(book.title))
    }
    var positionMs by remember(book.id, player) {
        mutableLongStateOf(player.currentPosition.coerceAtLeast(0L))
    }
    var scrubbing by remember(book.id, player) { mutableStateOf(false) }

    DisposableEffect(book.id, player) {
        val listener = object : Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) {
                uiState = player.audiobookUiState(book.title)
            }
        }
        player.addListener(listener)
        uiState = player.audiobookUiState(book.title)
        onDispose { player.removeListener(listener) }
    }

    LaunchedEffect(book.id, player, scrubbing) {
        while (true) {
            if (!scrubbing) {
                positionMs = player.currentPosition.coerceAtLeast(0L)
            }
            delay(250)
        }
    }

    val displayedPosition = positionMs.coerceIn(0L, maxOf(0L, uiState.durationMs))
    Column(
        modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(uiState.title, style = MaterialTheme.typography.headlineMedium)
        if (uiState.author.isNotBlank()) {
            Text(
                uiState.author,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
        if (uiState.chapter.isNotBlank()) {
            Text(
                uiState.chapter,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.padding(top = 20.dp),
            )
        }

        if (loading) {
            CircularProgressIndicator(Modifier.padding(top = 32.dp))
            Text("Preparing audiobook…", modifier = Modifier.padding(top = 12.dp))
        }

        Slider(
            value = displayedPosition.toFloat(),
            onValueChange = {
                scrubbing = true
                positionMs = it.toLong()
            },
            onValueChangeFinished = {
                player.seekTo(positionMs.coerceIn(0L, maxOf(0L, uiState.durationMs)))
                scrubbing = false
            },
            enabled = !loading && uiState.canSeek && uiState.durationMs > 0L,
            valueRange = 0f..maxOf(1L, uiState.durationMs).toFloat(),
            modifier = Modifier.fillMaxWidth().padding(top = 24.dp),
        )
        Text(
            "${formatPlaybackTime(displayedPosition)} / " +
                formatPlaybackTime(uiState.durationMs),
            style = MaterialTheme.typography.bodyMedium,
        )

        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 24.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Button(
                onClick = player::seekBack,
                enabled = !loading && uiState.canSeekBack,
            ) {
                Text("−15")
            }
            Button(
                onClick = { if (uiState.isPlaying) player.pause() else player.play() },
                enabled = !loading && uiState.canPlayPause,
            ) {
                Text(if (uiState.isPlaying) "Pause" else "Play")
            }
            Button(
                onClick = player::seekForward,
                enabled = !loading && uiState.canSeekForward,
            ) {
                Text("+15")
            }
        }
    }
}

private data class AudiobookUiState(
    val title: String,
    val author: String,
    val chapter: String,
    val durationMs: Long,
    val isPlaying: Boolean,
    val canPlayPause: Boolean,
    val canSeek: Boolean,
    val canSeekBack: Boolean,
    val canSeekForward: Boolean,
)

private fun Player.audiobookUiState(fallbackTitle: String): AudiobookUiState {
    val durationMs = duration.takeIf { it != C.TIME_UNSET && it > 0L } ?: 0L
    return AudiobookUiState(
        title = mediaMetadata.title?.toString()?.takeIf(String::isNotBlank) ?: fallbackTitle,
        author = mediaMetadata.albumTitle?.toString().orEmpty(),
        chapter = mediaMetadata.artist?.toString().orEmpty(),
        durationMs = durationMs,
        isPlaying = isPlaying,
        canPlayPause = isCommandAvailable(Player.COMMAND_PLAY_PAUSE),
        canSeek = isCommandAvailable(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM),
        canSeekBack = isCommandAvailable(Player.COMMAND_SEEK_BACK),
        canSeekForward = isCommandAvailable(Player.COMMAND_SEEK_FORWARD),
    )
}

private fun formatPlaybackTime(milliseconds: Long): String {
    val totalSeconds = milliseconds.coerceAtLeast(0L) / 1_000L
    val hours = totalSeconds / 3_600L
    val minutes = totalSeconds % 3_600L / 60L
    val seconds = totalSeconds % 60L
    return if (hours > 0L) {
        String.format(Locale.US, "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        String.format(Locale.US, "%d:%02d", minutes, seconds)
    }
}
