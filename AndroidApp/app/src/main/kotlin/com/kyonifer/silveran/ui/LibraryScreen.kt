package com.kyonifer.silveran.ui

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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.kyonifer.silveran.model.Book

@Composable
internal fun LibraryScreen(
    state: SilveranUiState,
    modifier: Modifier,
    configure: () -> Unit,
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
                        Surface(
                            modifier = Modifier.fillMaxWidth().aspectRatio(2f / 3f),
                            shape = RoundedCornerShape(6.dp),
                            tonalElevation = 2.dp,
                        ) {
                            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                Text("No cover", style = MaterialTheme.typography.bodySmall)
                            }
                        }
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
