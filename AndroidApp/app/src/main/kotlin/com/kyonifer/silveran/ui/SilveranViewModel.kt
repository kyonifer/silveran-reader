package com.kyonifer.silveran.ui

import android.content.Context
import android.graphics.Bitmap
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.kyonifer.silveran.bridge.SilveranBridgeClient
import com.kyonifer.silveran.model.Book
import com.kyonifer.silveran.model.StorytellerSettings
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
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
    val libraryLoaded: Boolean = false,
    val coverRevision: Int = 0,
    val sourceStatus: String = "notConfigured",
    val sourceMessage: String? = null,
    val refreshingLibrary: Boolean = false,
    val savingSettings: Boolean = false,
    val pendingDownloads: Set<String> = emptySet(),
    val successfulSettingsSaves: Int = 0,
    val error: String? = null,
)

class SilveranViewModel private constructor(
    private val client: SilveranBridgeClient,
) : ViewModel() {
    private val mutableState = MutableStateFlow(SilveranUiState())
    val state: StateFlow<SilveranUiState> = mutableState.asStateFlow()

    private val refreshMutex = Mutex()
    private val libraryChanges = Channel<Unit>(Channel.CONFLATED)

    init {
        viewModelScope.launch {
            for (change in libraryChanges) {
                delay(250)
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
            // BookServiceActor owns its startup network refresh. Render the
            // persisted snapshot now; its observer delivers the fresh result.
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
        val operation = "${book.key}:$category"
        mutableState.value = mutableState.value.copy(
            pendingDownloads = mutableState.value.pendingDownloads + operation,
            error = null,
        )
        viewModelScope.launch {
            runCatching {
                client.download(book, category)
                refreshLibraryNow(refresh = false)
            }.onFailure(::showError)
            mutableState.value = mutableState.value.copy(
                pendingDownloads = mutableState.value.pendingDownloads - operation,
            )
        }
    }

    fun cancelDownload(book: Book, category: String) {
        val operation = "${book.key}:$category"
        viewModelScope.launch {
            runCatching {
                client.cancelDownload(book, category)
                mutableState.value = mutableState.value.copy(
                    pendingDownloads = mutableState.value.pendingDownloads - operation,
                )
                refreshLibraryNow(refresh = false)
            }.onFailure(::showError)
        }
    }

    suspend fun cover(book: Book, width: Int, height: Int): Bitmap? =
        client.cover(book, width, height)

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
            mutableState.value = mutableState.value.copy(refreshingLibrary = true)
            try {
                val snapshot = client.librarySnapshot(refresh)
                val current = mutableState.value
                val settings = current.settings
                val refreshCovers = refresh || !current.libraryLoaded ||
                    current.sourceStatus != snapshot.sourceStatus ||
                    current.books.map(Book::key) != snapshot.books.map(Book::key)
                mutableState.value = current.copy(
                    books = snapshot.books,
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
                mutableState.value = mutableState.value.copy(refreshingLibrary = false)
            }
        }
    }

    private fun showError(error: Throwable) {
        mutableState.value = mutableState.value.copy(
            error = error.message ?: error.toString(),
            refreshingLibrary = false,
        )
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
