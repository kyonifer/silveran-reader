package com.kyonifer.silveran.ui

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.kyonifer.silveran.data.SilveranBridgeClient
import com.kyonifer.silveran.model.StorytellerSettings
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class SilveranUiState(
    val settingsLoaded: Boolean = false,
    val settings: StorytellerSettings = StorytellerSettings(),
    val savingSettings: Boolean = false,
    val error: String? = null,
)

class SilveranViewModel private constructor(
    private val client: SilveranBridgeClient,
) : ViewModel() {
    private val mutableState = MutableStateFlow(SilveranUiState())
    val state: StateFlow<SilveranUiState> = mutableState.asStateFlow()

    init {
        viewModelScope.launch {
            if (runCatching { client.bootstrap() }.onFailure(::showError).isFailure) {
                mutableState.value = mutableState.value.copy(settingsLoaded = true)
                return@launch
            }

            runCatching { loadSettings() }.onFailure { error ->
                mutableState.value = mutableState.value.copy(settingsLoaded = true)
                showError(error)
            }
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
                )
            }.onFailure { error ->
                mutableState.value = mutableState.value.copy(savingSettings = false)
                showError(error)
            }
        }
    }

    fun clearError() {
        mutableState.value = mutableState.value.copy(error = null)
    }

    private suspend fun loadSettings() {
        val settings = client.storytellerSettings()
        mutableState.value = mutableState.value.copy(
            settingsLoaded = true,
            settings = settings,
        )
    }

    private fun showError(error: Throwable) {
        mutableState.value = mutableState.value.copy(
            error = error.message ?: error.toString(),
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
