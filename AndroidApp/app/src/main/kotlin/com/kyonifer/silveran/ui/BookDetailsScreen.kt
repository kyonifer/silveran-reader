package com.kyonifer.silveran.ui

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.kyonifer.silveran.model.Book

@Composable
internal fun BookDetailsScreen(
    book: Book,
    pendingDownloads: Set<String>,
    coverRevision: Int,
    modifier: Modifier,
    cover: suspend (Book, Int, Int) -> Bitmap?,
    download: (String) -> Unit,
    cancelDownload: (String) -> Unit,
    open: (String) -> Unit,
) {
    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
    ) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            BookCover(
                book = book,
                width = 640,
                height = 960,
                revision = coverRevision,
                load = cover,
                modifier = Modifier.width(280.dp).height(420.dp),
            )
        }
        Text(book.title, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(top = 20.dp))
        if (book.authors.isNotBlank()) {
            Text(book.authors, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 4.dp))
        }
        book.description?.let { Text(it, modifier = Modifier.padding(top = 16.dp)) }
        HorizontalDivider(Modifier.padding(vertical = 20.dp))
        MediaActions(
            title = "Ebook",
            available = book.hasEbook,
            downloaded = book.ebookDownloaded,
            downloadState = book.ebookDownloadState,
            progress = book.ebookDownloadProgress,
            pending = "${book.key}:ebook" in pendingDownloads,
            playLabel = "Read",
            download = { download("ebook") },
            cancelDownload = { cancelDownload("ebook") },
            play = { open("ebook") },
        )
        MediaActions(
            title = "Audio",
            available = book.hasAudio,
            downloaded = book.audioDownloaded,
            downloadState = book.audioDownloadState,
            progress = book.audioDownloadProgress,
            pending = "${book.key}:audio" in pendingDownloads,
            playLabel = "Play",
            download = { download("audio") },
            cancelDownload = { cancelDownload("audio") },
            play = { open("audio") },
        )
    }
}

@Composable
private fun MediaActions(
    title: String,
    available: Boolean,
    downloaded: Boolean,
    downloadState: String?,
    progress: Double?,
    pending: Boolean,
    playLabel: String,
    download: () -> Unit,
    cancelDownload: () -> Unit,
    play: () -> Unit,
) {
    if (!available) return
    val cancellable = downloadState == "queued" || downloadState == "downloading"
    val finishing = downloadState == "importing" || downloadState == "completed"
    Column(Modifier.fillMaxWidth().padding(bottom = 16.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        when {
            downloaded -> Button(
                onClick = play,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            ) {
                Icon(Icons.Default.PlayArrow, contentDescription = null)
                Text(playLabel, modifier = Modifier.padding(start = 8.dp))
            }
            cancellable || finishing || pending -> {
                Text(
                    when {
                        pending -> "Starting download…"
                        downloadState == "importing" || downloadState == "completed" ->
                            "Finishing download…"
                        progress != null && progress > 0 ->
                            "Downloading ${(progress * 100).toInt()}%"
                        else -> "Downloading…"
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 8.dp),
                )
                if (progress != null && progress > 0) {
                    LinearProgressIndicator(
                        progress = { progress.toFloat().coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    )
                } else {
                    LinearProgressIndicator(
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    )
                }
                if (cancellable || pending) {
                    OutlinedButton(
                        onClick = cancelDownload,
                        enabled = !pending,
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    ) {
                        Icon(Icons.Default.Close, contentDescription = null)
                        Text("Cancel", modifier = Modifier.padding(start = 8.dp))
                    }
                }
            }
            else -> Button(
                onClick = download,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            ) {
                Icon(Icons.Default.KeyboardArrowDown, contentDescription = null)
                Text(
                    when (downloadState) {
                        "failed" -> "Retry"
                        "paused" -> "Resume"
                        else -> "Download"
                    },
                    modifier = Modifier.padding(start = 8.dp),
                )
            }
        }
    }
}
