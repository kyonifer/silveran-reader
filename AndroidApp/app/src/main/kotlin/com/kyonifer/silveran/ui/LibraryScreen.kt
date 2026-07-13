package com.kyonifer.silveran.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.kyonifer.silveran.R
import com.kyonifer.silveran.model.Book

private const val COVER_SCALE = 0.72f
private const val COVER_SPREAD = 0.08f
private const val EBOOK_ASPECT_RATIO = 0.67f
private const val PANEL_VERTICAL_MARGIN = 0.06f
internal const val COVER_PANEL_ASPECT_RATIO =
    1f / (COVER_SCALE / EBOOK_ASPECT_RATIO + PANEL_VERTICAL_MARGIN * 2f)

internal enum class LibraryTab(val label: String) {
    Home("Home"),
    Library("Library"),
    Downloaded("Downloaded"),
}

private sealed interface CoverLoadState {
    data object Loading : CoverLoadState
    data object Missing : CoverLoadState
    data class Loaded(val bitmap: Bitmap) : CoverLoadState
}

@Composable
internal fun LibraryScreen(
    state: SilveranUiState,
    tab: LibraryTab,
    searchText: String,
    modifier: Modifier,
    configure: () -> Unit,
    select: (Book) -> Unit,
    coverRevision: Int,
    cover: suspend (Book, Boolean, Int, Int) -> Bitmap?,
) {
    val visibleBooks = remember(state.books, tab, searchText) {
        val tabBooks = when (tab) {
            LibraryTab.Home -> state.books.sortedByDescending { it.createdAt.orEmpty() }
            LibraryTab.Library -> state.books.sortedBy { it.title.lowercase() }
            LibraryTab.Downloaded -> state.books
                .filter(Book::hasDownloadedMedia)
                .sortedBy { it.title.lowercase() }
        }
        val query = searchText.trim()
        if (query.isEmpty()) {
            tabBooks
        } else {
            tabBooks.filter { book ->
                book.title.contains(query, ignoreCase = true) ||
                    book.authors.contains(query, ignoreCase = true)
            }
        }
    }

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
            visibleBooks.isEmpty() && searchText.isNotBlank() -> EmptyLibrary(
                title = "No matches",
                message = "Try a different title or author.",
            )
            visibleBooks.isEmpty() && tab == LibraryTab.Downloaded -> EmptyLibrary(
                title = "No downloads",
                message = "Download a book from Home or Library to find it here.",
            )
            else -> LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                contentPadding = PaddingValues(12.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                items(visibleBooks, key = Book::key) { book ->
                    Column(Modifier.clickable { select(book) }) {
                        BookCover(
                            book = book,
                            width = 320,
                            height = 480,
                            revision = coverRevision,
                            load = cover,
                            modifier = Modifier.fillMaxWidth().aspectRatio(COVER_PANEL_ASPECT_RATIO),
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
@OptIn(ExperimentalMaterial3Api::class)
internal fun LibraryHeader(
    selectedTab: LibraryTab,
    searchText: String,
    refreshing: Boolean,
    refreshEnabled: Boolean,
    selectTab: (LibraryTab) -> Unit,
    updateSearch: (String) -> Unit,
    refresh: () -> Unit,
    openSettings: () -> Unit,
) {
    val focusManager = LocalFocusManager.current
    LaunchedEffect(Unit) {
        focusManager.clearFocus(force = true)
    }

    Surface(color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().statusBarsPadding()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextField(
                    value = searchText,
                    onValueChange = updateSearch,
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("Search books") },
                    leadingIcon = {
                        Icon(Icons.Default.Search, contentDescription = null)
                    },
                    trailingIcon = if (searchText.isNotEmpty()) {
                        {
                            IconButton(onClick = { updateSearch("") }) {
                                Icon(Icons.Default.Close, contentDescription = "Clear search")
                            }
                        }
                    } else {
                        null
                    },
                    singleLine = true,
                    shape = CircleShape,
                    colors = TextFieldDefaults.colors(
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                    ),
                )
                IconButton(onClick = refresh, enabled = refreshEnabled) {
                    if (refreshing) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp),
                            strokeWidth = 2.dp,
                        )
                    } else {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh library")
                    }
                }
                IconButton(onClick = openSettings) {
                    Icon(Icons.Default.Settings, contentDescription = "Server settings")
                }
            }
            PrimaryTabRow(selectedTabIndex = selectedTab.ordinal) {
                LibraryTab.entries.forEach { tab ->
                    Tab(
                        selected = selectedTab == tab,
                        onClick = { selectTab(tab) },
                        text = { Text(tab.label) },
                    )
                }
            }
        }
    }
}

@Composable
private fun EmptyLibrary(title: String, message: String, action: (() -> Unit)? = null) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(title, style = MaterialTheme.typography.headlineSmall)
            Text(message, modifier = Modifier.padding(top = 8.dp))
            if (action != null) {
                OutlinedButton(onClick = action, modifier = Modifier.padding(top = 16.dp)) {
                    Text("Open settings")
                }
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
    load: suspend (Book, Boolean, Int, Int) -> Bitmap?,
    modifier: Modifier,
) {
    val ebookState = rememberCoverLoadState(
        book = book,
        audio = false,
        available = book.hasEbook || book.hasReadaloud,
        width = width,
        height = height,
        revision = revision,
        load = load,
    )
    val audioState = rememberCoverLoadState(
        book = book,
        audio = true,
        available = book.hasAudio,
        width = width,
        height = width,
        revision = revision,
        load = load,
    )
    val ebookBitmap = (ebookState as? CoverLoadState.Loaded)?.bitmap
    val audioBitmap = (audioState as? CoverLoadState.Loaded)?.bitmap
    val ebookImage = remember(ebookBitmap) { ebookBitmap?.asImageBitmap() }
    val audioImage = remember(audioBitmap) { audioBitmap?.asImageBitmap() }
    val darkTheme = MaterialTheme.colorScheme.background.luminance() < 0.5f
    val backgroundColor = remember(ebookBitmap, audioBitmap, darkTheme) {
        coverBackgroundColor(ebookBitmap ?: audioBitmap, darkTheme)
    }
    val coverShape = RoundedCornerShape(6.dp)

    Surface(
        modifier = modifier,
        shape = coverShape,
        color = backgroundColor,
        shadowElevation = 2.dp,
    ) {
        BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            val coverWidth = maxWidth * COVER_SCALE
            val ebookHeight = coverWidth / EBOOK_ASPECT_RATIO
            val shift = maxWidth * COVER_SPREAD
            val hasBothCovers = ebookImage != null && audioImage != null

            if (audioImage != null) {
                Image(
                    bitmap = audioImage,
                    contentDescription = "${book.title} audiobook cover",
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .size(coverWidth)
                        .offset(x = if (hasBothCovers) shift else 0.dp)
                        .clip(coverShape)
                        .zIndex(1f),
                )
            }

            if (ebookImage != null) {
                Image(
                    bitmap = ebookImage,
                    contentDescription = "${book.title} ebook cover",
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .width(coverWidth)
                        .height(ebookHeight)
                        .offset(x = if (hasBothCovers) -shift else 0.dp)
                        .clip(coverShape)
                        .zIndex(2f),
                )
            }

            if (ebookImage == null && audioImage == null) {
                if (ebookState == CoverLoadState.Loading ||
                    audioState == CoverLoadState.Loading
                ) {
                    CircularProgressIndicator()
                } else {
                    Text("No cover", style = MaterialTheme.typography.bodySmall)
                }
            }

            if (book.hasReadaloud && (ebookImage != null || audioImage != null)) {
                Surface(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(4.dp)
                        .size(22.dp)
                        .zIndex(3f),
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.9f),
                ) {
                    Icon(
                        painter = painterResource(R.drawable.ic_readaloud),
                        contentDescription = "Readaloud available",
                        tint = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.padding(4.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun rememberCoverLoadState(
    book: Book,
    audio: Boolean,
    available: Boolean,
    width: Int,
    height: Int,
    revision: Int,
    load: suspend (Book, Boolean, Int, Int) -> Bitmap?,
): CoverLoadState {
    val state by produceState<CoverLoadState>(
        if (available) CoverLoadState.Loading else CoverLoadState.Missing,
        book.key,
        book.coverVersion,
        audio,
        available,
        width,
        height,
        revision,
    ) {
        if (!available) {
            value = CoverLoadState.Missing
            return@produceState
        }
        value = CoverLoadState.Loading
        value = runCatching { load(book, audio, width, height) }.getOrNull()
            ?.let(CoverLoadState::Loaded)
            ?: CoverLoadState.Missing
    }
    return state
}
