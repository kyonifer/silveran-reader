package com.kyonifer.silveran.ui

import android.content.Context
import android.graphics.Bitmap
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.kyonifer.silveran.bridge.SilveranBridgeClient
import com.kyonifer.silveran.model.AudiobookPlayerState
import com.kyonifer.silveran.model.Book
import com.kyonifer.silveran.model.BookDetails
import com.kyonifer.silveran.model.BookID
import com.kyonifer.silveran.model.DownloadOperation
import com.kyonifer.silveran.model.DownloadUpdate
import com.kyonifer.silveran.model.HomeSection
import com.kyonifer.silveran.model.SourceStatusUpdate
import com.kyonifer.silveran.model.StorytellerSettings
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class SilveranUiState(
    val settingsLoaded: Boolean = false,
    val settings: StorytellerSettings = StorytellerSettings(),
    val books: List<Book> = emptyList(),
    val bookDetails: Map<BookID, BookDetails> = emptyMap(),
    val homeSections: List<HomeSection> = emptyList(),
    val libraryLoaded: Boolean = false,
    val coverRevision: Int = 0,
    val sourceStatus: String = "notConfigured",
    val sourceMessage: String? = null,
    val libraryBusy: Boolean = false,
    val refreshingLibrary: Boolean = false,
    val savingSettings: Boolean = false,
    val pendingDownloads: Set<DownloadOperation> = emptySet(),
    val audiobookLoading: Boolean = false,
    val audiobook: AudiobookPlayerState? = null,
    val successfulSettingsSaves: Int = 0,
    val error: String? = null,
)

class SilveranViewModel private constructor(
    private val client: SilveranBridgeClient,
) : ViewModel() {
    private val mutableState = MutableStateFlow(SilveranUiState())
    val state: StateFlow<SilveranUiState> = mutableState.asStateFlow()

    private val refreshMutex = Mutex()
    private val audiobookMutex = Mutex()
    private val libraryChanges = Channel<Unit>(Channel.CONFLATED)
    private var currentAudiobookID: BookID? = null
    private var audiobookRequest = 0L
    private var downloadUpdates: Map<DownloadOperation, DownloadUpdate> = emptyMap()
    private val bookDetailsLoading = mutableSetOf<BookID>()

    init {
        client.observeAudiobookChanges { audiobook ->
            mutableState.value = mutableState.value.copy(audiobook = audiobook)
        }
        client.observeDownloadChanges { updates ->
            viewModelScope.launch { applyDownloadUpdates(updates) }
        }
        client.observeSourceStatusChanges { update ->
            viewModelScope.launch { applySourceStatus(update) }
        }
        viewModelScope.launch {
            for (change in libraryChanges) {
                runCatching { refreshLibraryNow(refresh = false) }.onFailure(::showError)
            }
        }
        viewModelScope.launch {
            if (runCatching { client.bootstrap() }.onFailure(::showError).isFailure) {
                mutableState.value = mutableState.value.copy(
                    settingsLoaded = true,
                    libraryLoaded = true,
                )
                return@launch
            }

            runCatching {
                client.observeLibraryChanges(::librarySnapshotDidChange)
            }.onFailure(::showError)
            runCatching { loadSettings() }.onFailure { error ->
                mutableState.value = mutableState.value.copy(settingsLoaded = true)
                showError(error)
            }
            runCatching { refreshLibraryNow(refresh = false) }.onFailure { error ->
                mutableState.value = mutableState.value.copy(libraryLoaded = true)
                showError(error)
            }
        }
    }

    fun refreshLibrary() {
        viewModelScope.launch {
            runCatching { refreshLibraryNow(refresh = true) }.onFailure(::showError)
        }
    }

    fun loadBookDetails(book: Book) {
        val details = mutableState.value.bookDetails[book.id]
        if (details?.version == book.coverVersion || !bookDetailsLoading.add(book.id)) return

        viewModelScope.launch {
            runCatching { client.bookDetails(book) }
                .onSuccess { loaded ->
                    val current = mutableState.value
                    val currentBook = current.books.firstOrNull { it.id == book.id }
                    if (currentBook?.coverVersion == loaded.version) {
                        mutableState.value = current.copy(
                            bookDetails = current.bookDetails + (book.id to loaded),
                        )
                    }
                }
                .onFailure(::showError)
            bookDetailsLoading.remove(book.id)
        }
    }

    fun saveSettings(serverURL: String, username: String, password: String) {
        mutableState.value = mutableState.value.copy(savingSettings = true, error = null)
        viewModelScope.launch {
            runCatching {
                val settings = client.saveStorytellerSettings(serverURL, username, password)
                mutableState.value = mutableState.value.copy(
                    settingsLoaded = true,
                    settings = settings,
                    savingSettings = false,
                    successfulSettingsSaves = mutableState.value.successfulSettingsSaves + 1,
                )
                // The save bridge has already refreshed the source.
                refreshLibraryNow(refresh = false)
            }.onFailure { error ->
                mutableState.value = mutableState.value.copy(savingSettings = false)
                showError(error)
            }
        }
    }

    fun download(book: Book, category: String) {
        val operation = DownloadOperation(book.id, category)
        mutableState.value = mutableState.value.copy(
            pendingDownloads = mutableState.value.pendingDownloads + operation,
            error = null,
        )
        viewModelScope.launch {
            runCatching {
                client.download(book, category)
            }.onFailure(::showError)
            mutableState.value = mutableState.value.copy(
                pendingDownloads = mutableState.value.pendingDownloads - operation,
            )
        }
    }

    fun cancelDownload(book: Book, category: String) {
        val operation = DownloadOperation(book.id, category)
        viewModelScope.launch {
            runCatching {
                client.cancelDownload(book, category)
                mutableState.value = mutableState.value.copy(
                    pendingDownloads = mutableState.value.pendingDownloads - operation,
                )
            }.onFailure(::showError)
        }
    }

    fun deleteDownload(book: Book, category: String) {
        viewModelScope.launch {
            runCatching {
                client.deleteDownload(book, category)
                refreshLibraryNow(refresh = false)
            }.onFailure(::showError)
        }
    }

    fun openAudiobook(book: Book) {
        val sharedAudiobookID = mutableState.value.audiobook?.bookID
        if (currentAudiobookID == book.id || sharedAudiobookID == book.id) {
            currentAudiobookID = book.id
            return
        }
        currentAudiobookID = book.id
        val request = ++audiobookRequest
        mutableState.value = mutableState.value.copy(audiobookLoading = true, error = null)
        viewModelScope.launch {
            val result = runCatching {
                audiobookMutex.withLock { client.openAudiobook(book) }
            }
            if (request != audiobookRequest) return@launch
            result.onFailure(::showError)
            mutableState.value = mutableState.value.copy(audiobookLoading = false)
        }
    }

    fun closeAudiobook() {
        currentAudiobookID = null
        val request = ++audiobookRequest
        mutableState.value = mutableState.value.copy(audiobookLoading = false)
        viewModelScope.launch {
            val result = runCatching {
                audiobookMutex.withLock { client.closeAudiobook() }
            }
            if (request == audiobookRequest) result.onFailure(::showError)
        }
    }

    fun toggleAudiobookPlayback() = controlAudiobook("togglePlayPause")

    fun skipAudiobookBackward() = controlAudiobook("skipBackward")

    fun skipAudiobookForward() = controlAudiobook("skipForward")

    fun previousAudiobookChapter() = controlAudiobook("previousChapter")

    fun nextAudiobookChapter() = controlAudiobook("nextChapter")

    fun seekAudiobookChapter(fraction: Double) =
        controlAudiobook("seekChapterFraction", value = fraction)

    fun selectAudiobookChapter(chapterID: String) =
        controlAudiobook("selectChapter", text = chapterID)

    fun setAudiobookPlaybackRate(rate: Double) =
        controlAudiobook("setPlaybackRate", value = rate)

    fun setAudiobookVolume(volume: Double) =
        controlAudiobook("setVolume", value = volume)

    fun startAudiobookSleepTimer(seconds: Double) =
        controlAudiobook("startSleepTimer", value = seconds)

    fun startAudiobookEndOfChapterSleepTimer() =
        controlAudiobook("startEndOfChapterSleepTimer")

    fun cancelAudiobookSleepTimer() = controlAudiobook("cancelSleepTimer")

    fun acceptAudiobookServerPosition() = controlAudiobook("acceptServerPosition")

    fun declineAudiobookServerPosition() = controlAudiobook("declineServerPosition")

    suspend fun cover(book: Book, audio: Boolean, width: Int, height: Int): Bitmap? =
        client.cover(book, audio, width, height)

    fun cachedCover(book: Book, audio: Boolean): Bitmap? = client.cachedCover(book, audio)

    fun clearError() {
        mutableState.value = mutableState.value.copy(error = null)
    }

    override fun onCleared() {
        libraryChanges.close()
        client.close()
        super.onCleared()
    }

    private suspend fun loadSettings() {
        val settings = client.storytellerSettings()
        mutableState.value = mutableState.value.copy(
            settingsLoaded = true,
            settings = settings,
        )
    }

    private fun librarySnapshotDidChange() {
        libraryChanges.trySend(Unit)
    }

    private suspend fun refreshLibraryNow(refresh: Boolean) {
        refreshMutex.withLock {
            mutableState.value = mutableState.value.copy(
                libraryBusy = true,
                refreshingLibrary = refresh,
            )
            try {
                val snapshot = client.librarySnapshot(refresh)
                val current = mutableState.value
                val settings = current.settings
                val refreshCovers = refresh || !current.libraryLoaded ||
                    current.sourceStatus != snapshot.sourceStatus ||
                    current.books.map(Book::coverIdentity) !=
                    snapshot.books.map(Book::coverIdentity)
                val books = updateDownloadStates(
                    books = snapshot.books,
                    updates = downloadUpdates,
                    operations = downloadUpdates.keys,
                )
                val versions = books.associate { it.id to it.coverVersion }
                mutableState.value = current.copy(
                    books = books,
                    bookDetails = current.bookDetails.filter { (id, details) ->
                        versions[id] == details.version
                    },
                    homeSections = snapshot.homeSections,
                    libraryLoaded = true,
                    coverRevision = current.coverRevision + if (refreshCovers) 1 else 0,
                    sourceStatus = snapshot.sourceStatus,
                    sourceMessage = snapshot.sourceMessage,
                    settings = if (settings.configured) {
                        settings.copy(
                            connectionStatus = snapshot.sourceStatus,
                            connectionMessage = snapshot.sourceMessage,
                        )
                    } else {
                        settings
                    },
                )
            } finally {
                mutableState.value = mutableState.value.copy(
                    libraryBusy = false,
                    refreshingLibrary = false,
                )
            }
        }
    }

    private fun applyDownloadUpdates(updates: List<DownloadUpdate>) {
        val next = updates.associateBy(DownloadUpdate::operation)
        val affected = downloadUpdates.keys + next.keys
        downloadUpdates = next
        val current = mutableState.value
        mutableState.value = current.copy(
            books = updateDownloadStates(current.books, next, affected),
        )
    }

    private fun applySourceStatus(update: SourceStatusUpdate) {
        val current = mutableState.value
        mutableState.value = current.copy(
            sourceStatus = update.status,
            sourceMessage = update.message,
            settings = if (current.settings.configured) {
                current.settings.copy(
                    connectionStatus = update.status,
                    connectionMessage = update.message,
                )
            } else {
                current.settings
            },
        )
    }

    private fun updateDownloadStates(
        books: List<Book>,
        updates: Map<DownloadOperation, DownloadUpdate>,
        operations: Set<DownloadOperation>,
    ): List<Book> {
        if (operations.isEmpty()) return books
        val affectedBookIDs = operations.mapTo(mutableSetOf(), DownloadOperation::bookID)
        return books.map { book ->
            if (book.id !in affectedBookIDs) return@map book
            book.copy(
                media = book.media.map { media ->
                    val operation = DownloadOperation(book.id, media.category)
                    if (operation !in operations) return@map media
                    val update = updates[operation]
                    media.copy(
                        downloadState = update?.state,
                        downloadProgress = update?.progress,
                    )
                },
            )
        }
    }

    private fun showError(error: Throwable) {
        mutableState.value = mutableState.value.copy(
            error = error.message ?: error.toString(),
            libraryBusy = false,
            refreshingLibrary = false,
        )
    }

    private fun controlAudiobook(
        command: String,
        value: Double = 0.0,
        text: String = "",
    ) {
        viewModelScope.launch {
            runCatching {
                client.controlAudiobook(command, value, text)
            }.onFailure(::showError)
        }
    }

    companion object {
        fun factory(context: Context): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    SilveranViewModel(SilveranBridgeClient(context.applicationContext)) as T
            }
    }
}

private data class CoverIdentity(
    val id: BookID,
    val version: String,
    val hasEbook: Boolean,
    val hasAudio: Boolean,
    val hasReadaloud: Boolean,
)

private fun Book.coverIdentity() = CoverIdentity(
    id = id,
    version = coverVersion,
    hasEbook = hasEbook,
    hasAudio = hasAudio,
    hasReadaloud = hasReadaloud,
)
