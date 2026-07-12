package com.kyonifer.silveran.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import com.kyonifer.silveran.model.Book

@Composable
internal fun LibraryScreen(
    state: SilveranUiState,
    modifier: Modifier,
    configure: () -> Unit,
    coverRevision: Int,
    cover: suspend (Book, Int, Int) -> Bitmap?,
) {
    Column(modifier.fillMaxSize()) {
        state.sourceMessage?.let { message ->
            Surface(color = MaterialTheme.colorScheme.errorContainer) {
                Text(
                    message,
                    color = MaterialTheme.colorScheme.onErrorContainer,
                    modifier = Modifier.fillMaxWidth().padding(12.dp),
                )
            }
        }
        when {
            !state.settingsLoaded ||
                (state.settings.configured && !state.libraryLoaded) ->
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            !state.settings.configured -> EmptyLibrary(
                title = "No server configured",
                message = "Save a Storyteller source in Settings to load its library.",
                action = configure,
            )
            state.books.isEmpty() -> EmptyLibrary(
                title = "No books",
                message = connectionText(state.sourceStatus, state.sourceMessage),
                action = configure,
            )
            else -> LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                contentPadding = PaddingValues(12.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                items(state.books, key = Book::key) { book ->
                    Column {
                        BookCover(
                            book = book,
                            width = 320,
                            height = 480,
                            revision = coverRevision,
                            load = cover,
                            modifier = Modifier.fillMaxWidth().aspectRatio(2f / 3f),
                        )
                        Text(
                            book.title,
                            style = MaterialTheme.typography.titleSmall,
                            maxLines = 2,
                            modifier = Modifier.padding(top = 6.dp),
                        )
                        if (book.authors.isNotBlank()) {
                            Text(
                                book.authors,
                                style = MaterialTheme.typography.bodySmall,
                                maxLines = 1,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyLibrary(title: String, message: String, action: () -> Unit) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(title, style = MaterialTheme.typography.headlineSmall)
            Text(message, modifier = Modifier.padding(top = 8.dp))
            OutlinedButton(onClick = action, modifier = Modifier.padding(top = 16.dp)) {
                Text("Open settings")
            }
        }
    }
}

@Composable
internal fun BookCover(
    book: Book,
    width: Int,
    height: Int,
    revision: Int,
    load: suspend (Book, Int, Int) -> Bitmap?,
    modifier: Modifier,
) {
    val bitmap by produceState<Bitmap?>(
        null,
        book.key,
        book.coverVersion,
        width,
        height,
        revision,
    ) {
        value = runCatching { load(book, width, height) }.getOrNull()
    }
    val imageBitmap = remember(bitmap) {
        bitmap?.asImageBitmap()
    }
    Surface(modifier, shape = RoundedCornerShape(6.dp), tonalElevation = 2.dp) {
        if (imageBitmap == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No cover", style = MaterialTheme.typography.bodySmall)
            }
        } else {
            Image(
                bitmap = imageBitmap!!,
                contentDescription = book.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}
