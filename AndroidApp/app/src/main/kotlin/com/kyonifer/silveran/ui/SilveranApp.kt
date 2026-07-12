package com.kyonifer.silveran.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier

private enum class Screen {
    Library,
    Settings,
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SilveranApp(viewModel: SilveranViewModel) {
    val state by viewModel.state.collectAsState()
    val snackbar = remember { SnackbarHostState() }
    var screenName by rememberSaveable { mutableStateOf(Screen.Library.name) }
    var settingsSavePending by remember { mutableStateOf(false) }
    val screen = Screen.valueOf(screenName)
    val canNavigateBack = screen == Screen.Settings && state.settings.configured
    val navigateBack = {
        screenName = Screen.Library.name
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
    LaunchedEffect(state.successfulSettingsSaves) {
        if (settingsSavePending) {
            settingsSavePending = false
            screenName = Screen.Library.name
        }
    }
    BackHandler(enabled = canNavigateBack, onBack = navigateBack)

    MaterialTheme {
        Scaffold(
            snackbarHost = { SnackbarHost(snackbar) },
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            when (screen) {
                                Screen.Library -> "Library"
                                Screen.Settings -> "Server settings"
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
                    actions = {
                        if (screen == Screen.Library) {
                            IconButton(
                                onClick = viewModel::refreshLibrary,
                                enabled = !state.refreshingLibrary && state.settings.configured,
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Refresh,
                                    contentDescription = "Refresh library",
                                )
                            }
                            IconButton(onClick = { screenName = Screen.Settings.name }) {
                                Icon(
                                    imageVector = Icons.Default.Settings,
                                    contentDescription = "Server settings",
                                )
                            }
                        }
                    },
                )
            },
        ) { padding ->
            when (screen) {
                Screen.Library -> LibraryScreen(
                    state = state,
                    modifier = Modifier.padding(padding),
                    configure = { screenName = Screen.Settings.name },
                    coverRevision = state.coverRevision,
                    cover = viewModel::cover,
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
            }
        }
    }
}
