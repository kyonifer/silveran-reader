package com.kyonifer.silveran.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.kyonifer.silveran.model.Book
import com.kyonifer.silveran.model.BookDetails
import com.kyonifer.silveran.model.BookID

private enum class Screen {
    Library,
    Settings,
    Details,
    Reader,
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SilveranApp(viewModel: SilveranViewModel) {
    val state by viewModel.state.collectAsState()
    val snackbar = remember { SnackbarHostState() }
    var screenName by rememberSaveable { mutableStateOf(Screen.Library.name) }
    var selectedBookID by rememberSaveable { mutableStateOf<BookID?>(null) }
    var readerMode by rememberSaveable { mutableStateOf("ebook") }
    var libraryTabName by rememberSaveable { mutableStateOf(LibraryTab.Home.name) }
    var librarySearchText by rememberSaveable { mutableStateOf("") }
    var settingsSavePending by remember { mutableStateOf(false) }
    val screen = Screen.valueOf(screenName)
    val libraryTab = LibraryTab.valueOf(libraryTabName)
    val selectedBookSummary = state.books.firstOrNull { it.id == selectedBookID }
    val selectedBook = selectedBookSummary?.let { book ->
        state.bookDetails[book.id]
            ?.takeIf { it.version == book.coverVersion }
            ?.let(book::withDetails)
            ?: book
    }
    val canNavigateBack = screen == Screen.Details || screen == Screen.Reader ||
        (screen == Screen.Settings && state.settings.configured)
    val navigateBack = {
        if (screen == Screen.Reader) {
            if (readerMode == "audio") {
                viewModel.closeAudiobook()
            } else {
                viewModel.closeReader()
            }
        }
        screenName = when (screen) {
            Screen.Reader -> Screen.Details.name
            else -> Screen.Library.name
        }
    }

    LaunchedEffect(state.settingsLoaded, state.settings.configured) {
        if (state.settingsLoaded && !state.settings.configured) {
            screenName = Screen.Settings.name
        }
    }
    LaunchedEffect(state.error) {
        state.error?.let {
            snackbar.showSnackbar(it)
            viewModel.clearError()
        }
    }
    LaunchedEffect(screen, selectedBook, state.libraryLoaded) {
        if (state.libraryLoaded &&
            (screen == Screen.Details || screen == Screen.Reader) &&
            selectedBook == null
        ) {
            if (screen == Screen.Reader) {
                if (readerMode == "audio") {
                    viewModel.closeAudiobook()
                } else {
                    viewModel.closeReader()
                }
            }
            screenName = Screen.Library.name
        }
    }
    LaunchedEffect(screen, readerMode, selectedBook?.id) {
        if (screen == Screen.Reader && readerMode == "audio") {
            selectedBook?.let(viewModel::openAudiobook)
        } else if (screen == Screen.Reader) {
            selectedBook?.let { viewModel.openReader(it, readerMode) }
        }
    }
    LaunchedEffect(screen, selectedBookSummary?.id, selectedBookSummary?.coverVersion) {
        if (screen == Screen.Details) selectedBookSummary?.let(viewModel::loadBookDetails)
    }
    LaunchedEffect(state.successfulSettingsSaves) {
        if (settingsSavePending) {
            settingsSavePending = false
            screenName = Screen.Library.name
        }
    }
    BackHandler(enabled = canNavigateBack, onBack = navigateBack)

    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme(),
    ) {
        Scaffold(
            snackbarHost = { SnackbarHost(snackbar) },
            topBar = {
                if (screen == Screen.Library) {
                    LibraryHeader(
                        selectedTab = libraryTab,
                        searchText = librarySearchText,
                        refreshing = state.refreshingLibrary,
                        refreshEnabled = !state.libraryBusy && state.settings.configured,
                        selectTab = { libraryTabName = it.name },
                        updateSearch = { librarySearchText = it },
                        refresh = viewModel::refreshLibrary,
                        openSettings = { screenName = Screen.Settings.name },
                    )
                } else if (screen != Screen.Details &&
                    !(screen == Screen.Reader && readerMode != "audio")
                ) {
                    TopAppBar(
                        title = {
                            Text(
                                when (screen) {
                                    Screen.Library -> "Library"
                                    Screen.Settings -> "Server settings"
                                    Screen.Details -> ""
                                    Screen.Reader -> if (readerMode == "audio") "Player" else "Reader"
                                },
                                maxLines = 1,
                            )
                        },
                        navigationIcon = {
                            if (canNavigateBack) {
                                IconButton(onClick = navigateBack) {
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                                        contentDescription = "Back",
                                    )
                                }
                            }
                        },
                    )
                }
            },
        ) { padding ->
            when (screen) {
                Screen.Library -> LibraryScreen(
                    state = state,
                    tab = libraryTab,
                    searchText = librarySearchText,
                    modifier = Modifier.padding(padding),
                    configure = { screenName = Screen.Settings.name },
                    select = { book ->
                        selectedBookID = book.id
                        screenName = Screen.Details.name
                    },
                    coverRevision = state.coverRevision,
                    cover = viewModel::cover,
                    cachedCover = viewModel::cachedCover,
                )
                Screen.Settings -> SettingsScreen(
                    settings = state.settings,
                    settingsLoaded = state.settingsLoaded,
                    saving = state.savingSettings,
                    modifier = Modifier.padding(padding),
                    save = { serverURL, username, password ->
                        settingsSavePending = true
                        viewModel.saveSettings(serverURL, username, password)
                    },
                )
                Screen.Details -> selectedBook?.let { book ->
                    BookDetailsScreen(
                        book = book,
                        library = state.books,
                        pendingDownloads = state.pendingDownloads,
                        coverRevision = state.coverRevision,
                        modifier = Modifier.padding(bottom = padding.calculateBottomPadding()),
                        navigateBack = navigateBack,
                        openSettings = { screenName = Screen.Settings.name },
                        cover = viewModel::cover,
                        cachedCover = viewModel::cachedCover,
                        download = { category -> viewModel.download(book, category) },
                        cancelDownload = { category ->
                            viewModel.cancelDownload(book, category)
                        },
                        deleteDownload = { category ->
                            viewModel.deleteDownload(book, category)
                        },
                        open = { mode ->
                            readerMode = mode
                            screenName = Screen.Reader.name
                        },
                        selectRelated = { related -> selectedBookID = related.id },
                    )
                }
                Screen.Reader -> selectedBook?.let { book ->
                    if (readerMode == "audio") {
                        MediaSessionAudiobookPlayerScreen(
                            book = book,
                            state = state.audiobook?.takeIf { it.bookID == book.id },
                            loading = state.audiobookLoading,
                            modifier = Modifier.padding(padding),
                            togglePlayPause = viewModel::toggleAudiobookPlayback,
                            skipBackward = viewModel::skipAudiobookBackward,
                            skipForward = viewModel::skipAudiobookForward,
                            previousChapter = viewModel::previousAudiobookChapter,
                            nextChapter = viewModel::nextAudiobookChapter,
                            seekChapter = viewModel::seekAudiobookChapter,
                            selectChapter = viewModel::selectAudiobookChapter,
                            setPlaybackRate = viewModel::setAudiobookPlaybackRate,
                            setVolume = viewModel::setAudiobookVolume,
                            startSleepTimer = viewModel::startAudiobookSleepTimer,
                            startEndOfChapterSleepTimer =
                                viewModel::startAudiobookEndOfChapterSleepTimer,
                            cancelSleepTimer = viewModel::cancelAudiobookSleepTimer,
                            acceptServerPosition = viewModel::acceptAudiobookServerPosition,
                            declineServerPosition = viewModel::declineAudiobookServerPosition,
                        )
                    } else {
                        ReaderScreen(
                            book = book,
                            mode = readerMode,
                            openResult = state.readerOpen,
                            readerState = state.reader,
                            navigateBack = navigateBack,
                            readerControl = viewModel::readerControl,
                            readerMessageFromJS = viewModel::readerMessageFromJS,
                            registerWebView = viewModel::registerReaderWebView,
                            unregisterWebView = viewModel::unregisterReaderWebView,
                            modifier = Modifier,
                        )
                    }
                }
            }
        }
    }
}

private fun Book.withDetails(details: BookDetails) = copy(
    description = details.description,
    publicationDateDisplay = details.publicationDateDisplay,
    createdAtDisplay = details.createdAtDisplay,
    updatedAtDisplay = details.updatedAtDisplay,
)
