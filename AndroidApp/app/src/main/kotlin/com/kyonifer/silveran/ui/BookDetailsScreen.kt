package com.kyonifer.silveran.ui

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.kyonifer.silveran.model.Book

@Composable
internal fun BookDetailsScreen(
    book: Book,
    pendingDownloads: Set<String>,
    coverRevision: Int,
    modifier: Modifier,
    cover: suspend (Book, Boolean, Int, Int) -> Bitmap?,
    download: (String) -> Unit,
    cancelDownload: (String) -> Unit,
    deleteDownload: (String) -> Unit,
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
                modifier = Modifier.width(280.dp).aspectRatio(COVER_PANEL_ASPECT_RATIO),
            )
        }
        Text(book.title, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(top = 20.dp))
        if (book.authors.isNotBlank()) {
            Text(book.authors, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 4.dp))
        }
        MediaActions(
            book = book,
            pendingDownloads = pendingDownloads,
            modifier = Modifier.padding(top = 20.dp),
            download = download,
            cancelDownload = cancelDownload,
            deleteDownload = deleteDownload,
            open = open,
        )
        book.description?.let {
            HorizontalDivider(Modifier.padding(vertical = 20.dp))
            Text(it)
        }
    }
}

@Composable
private fun MediaActions(
    book: Book,
    pendingDownloads: Set<String>,
    modifier: Modifier = Modifier,
    download: (String) -> Unit,
    cancelDownload: (String) -> Unit,
    deleteDownload: (String) -> Unit,
    open: (String) -> Unit,
) {
    val options = book.media.mapNotNull { media ->
        val title = when (media.category) {
            "ebook" -> "Ebook"
            "audio" -> "Audiobook"
            "synced" -> "Readaloud"
            else -> return@mapNotNull null
        }
        MediaActionOption(
            category = media.category,
            title = title,
            downloaded = media.downloaded,
            removable = media.removable,
            downloadState = media.downloadState,
            progress = media.downloadProgress,
        )
    }
    if (options.isEmpty()) return

    var pendingDeletion by remember { mutableStateOf<MediaActionOption?>(null) }
    Row(
        modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.Top,
    ) {
        options.forEach { option ->
            MediaAction(
                option = option,
                pending = "${book.key}:${option.category}" in pendingDownloads,
                modifier = Modifier.weight(1f),
                download = { download(option.category) },
                cancelDownload = { cancelDownload(option.category) },
                deleteDownload = { pendingDeletion = option },
                play = { open(option.category) },
            )
        }
    }

    pendingDeletion?.let { option ->
        AlertDialog(
            onDismissRequest = { pendingDeletion = null },
            title = { Text("Delete download?") },
            text = { Text("Remove the downloaded ${option.title.lowercase()} from this device?") },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingDeletion = null
                        deleteDownload(option.category)
                    },
                ) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDeletion = null }) {
                    Text("Cancel")
                }
            },
        )
    }
}

private data class MediaActionOption(
    val category: String,
    val title: String,
    val downloaded: Boolean,
    val removable: Boolean,
    val downloadState: String?,
    val progress: Double?,
)

@Composable
private fun MediaAction(
    option: MediaActionOption,
    pending: Boolean,
    modifier: Modifier,
    download: () -> Unit,
    cancelDownload: () -> Unit,
    deleteDownload: () -> Unit,
    play: () -> Unit,
) {
    val downloadIconRotation =
        if (LocalLayoutDirection.current == LayoutDirection.Ltr) 90f else -90f
    val cancellable = option.downloadState == "queued" ||
        option.downloadState == "downloading"
    val finishing = option.downloadState == "importing" ||
        option.downloadState == "completed"
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        when {
            option.downloaded -> FilledTonalButton(
                onClick = play,
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                contentPadding = MediaActionContentPadding,
            ) {
                Icon(Icons.Default.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(4.dp))
                MediaActionLabel(option.title)
            }
            cancellable || finishing || pending -> {
                OutlinedButton(
                    onClick = cancelDownload,
                    enabled = cancellable,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                    contentPadding = MediaActionContentPadding,
                ) {
                    MediaProgress(option.progress)
                    Spacer(Modifier.width(4.dp))
                    MediaActionLabel(option.title)
                    if (cancellable) {
                        Spacer(Modifier.width(2.dp))
                        Icon(
                            Icons.Default.Close,
                            contentDescription = null,
                            modifier = Modifier.size(14.dp),
                        )
                    }
                }
                if (option.progress != null && option.progress > 0) {
                    LinearProgressIndicator(
                        progress = { option.progress.toFloat().coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth().padding(top = 4.dp).height(2.dp),
                    )
                }
            }
            else -> Button(
                onClick = download,
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                contentPadding = MediaActionContentPadding,
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.ExitToApp,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp).rotate(downloadIconRotation),
                )
                Spacer(Modifier.width(4.dp))
                MediaActionLabel(option.title)
            }
        }
        if (option.downloaded && option.removable) {
            TextButton(onClick = deleteDownload, contentPadding = PaddingValues(8.dp)) {
                Icon(
                    Icons.Default.Delete,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(4.dp))
                Text("Delete", style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

@Composable
private fun MediaActionLabel(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.labelMedium,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
private fun MediaProgress(progress: Double?) {
    if (progress != null && progress > 0) {
        CircularProgressIndicator(
            progress = { progress.toFloat().coerceIn(0f, 1f) },
            modifier = Modifier.size(18.dp),
            strokeWidth = 2.dp,
        )
    } else {
        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
    }
}

private val MediaActionContentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp)
