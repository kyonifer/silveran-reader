package com.kyonifer.silveran.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.kyonifer.silveran.model.StorytellerSettings

@Composable
internal fun SettingsScreen(
    settings: StorytellerSettings,
    settingsLoaded: Boolean,
    saving: Boolean,
    modifier: Modifier,
    save: (String, String, String) -> Unit,
) {
    var serverURL by rememberSaveable { mutableStateOf("") }
    var username by rememberSaveable { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var loadedSourceID by rememberSaveable { mutableStateOf<String?>(null) }

    LaunchedEffect(settingsLoaded, settings.sourceID) {
        if (!settingsLoaded) return@LaunchedEffect
        val sourceKey = settings.sourceID ?: "new"
        if (loadedSourceID != sourceKey) {
            serverURL = settings.serverURL
            username = settings.username
            password = ""
            loadedSourceID = sourceKey
        }
    }

    val canSave = !saving && serverURL.isNotBlank() && username.isNotBlank() &&
        (settings.configured || password.isNotBlank())
    val submit = {
        val submittedPassword = password
        password = ""
        save(serverURL, username, submittedPassword)
    }
    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            "Add the Storyteller server used by this device. The source registry and " +
                "credentials are persisted through the Android platform providers.",
            style = MaterialTheme.typography.bodyMedium,
        )
        OutlinedTextField(
            value = serverURL,
            onValueChange = { serverURL = it },
            label = { Text("Server URL") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = username,
            onValueChange = { username = it },
            label = { Text("Username or email") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = password,
            onValueChange = { password = it },
            label = { Text("Password") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            supportingText = {
                if (settings.configured) Text("Leave blank to keep the saved password")
            },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = {
                if (canSave) submit()
            }),
            modifier = Modifier.fillMaxWidth(),
        )
        Button(
            onClick = submit,
            enabled = canSave,
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (saving) {
                CircularProgressIndicator(
                    strokeWidth = 2.dp,
                    modifier = Modifier.width(18.dp).height(18.dp),
                )
                Spacer(Modifier.width(8.dp))
            }
            Text(if (saving) "Saving" else "Save server")
        }
        if (settings.configured) {
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            Text("Saved", style = MaterialTheme.typography.titleMedium)
            Text(connectionText(settings.connectionStatus, settings.connectionMessage))
        }
    }
}

internal fun connectionText(status: String, message: String?): String =
    message ?: when (status) {
        "connected" -> "Connected"
        "connecting" -> "Connecting"
        "disconnected" -> "Saved; not currently connected"
        "error" -> "Could not connect"
        else -> "Not configured"
    }
