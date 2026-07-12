package com.kyonifer.silveran.bridge

import android.content.Context
import com.kyonifer.silveran.model.Book
import com.kyonifer.silveran.model.LibrarySnapshot
import com.kyonifer.silveran.model.StorytellerSettings
import com.kyonifer.silveran.platform.AndroidSecureStore
import java.util.concurrent.CompletableFuture
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.json.JSONObject

class SilveranBridgeClient(context: Context) {
    private val applicationContext = context.applicationContext
    private val filesDirectory = context.filesDir.absolutePath

    fun bootstrap() {
        AndroidSecureStore.initialize(applicationContext)
        SilveranAndroidBridge.bootstrapAndroid(filesDirectory)
    }

    suspend fun observeLibraryChanges(onChange: () -> Unit) {
        AndroidBridgeCallbacks.observe(onChange)
        SilveranAndroidBridge.startLibraryObservation().awaitResult()
    }

    fun close() {
        AndroidBridgeCallbacks.clear()
    }

    suspend fun storytellerSettings(): StorytellerSettings {
        val json = SilveranAndroidBridge.storytellerSettingsJSON().awaitResult()
        return withContext(Dispatchers.Default) { parseSettings(json) }
    }

    suspend fun librarySnapshot(refresh: Boolean): LibrarySnapshot {
        val json = SilveranAndroidBridge.librarySnapshotJSON(refresh).awaitResult()
        return withContext(Dispatchers.Default) { parseLibrary(json) }
    }

    suspend fun saveStorytellerSettings(
        serverURL: String,
        username: String,
        password: String,
    ): StorytellerSettings {
        val json = SilveranAndroidBridge.saveStorytellerSettings(
            serverURL,
            username,
            password,
        ).awaitResult()
        return withContext(Dispatchers.Default) { parseSettings(json) }
    }

    private fun parseSettings(json: String): StorytellerSettings {
        val root = JSONObject(json)
        return StorytellerSettings(
            configured = root.getBoolean("configured"),
            sourceID = root.optionalString("sourceID"),
            serverURL = root.optString("serverURL"),
            username = root.optString("username"),
            connectionStatus = root.optString("connectionStatus", "notConfigured"),
            connectionMessage = root.optionalString("connectionMessage"),
        )
    }

    private fun parseLibrary(json: String): LibrarySnapshot {
        val root = JSONObject(json)
        val items = root.getJSONArray("books")
        val books = List(items.length()) { index ->
            val item = items.getJSONObject(index)
            Book(
                id = item.getString("id"),
                sourceID = item.getString("sourceID"),
                title = item.getString("title"),
                authors = item.optString("authors"),
            )
        }
        return LibrarySnapshot(
            books = books,
            sourceStatus = root.optString("sourceStatus", "notConfigured"),
            sourceMessage = root.optionalString("sourceMessage"),
        )
    }
}

private fun JSONObject.optionalString(name: String): String? =
    if (isNull(name)) null else optString(name).takeIf(String::isNotBlank)

private suspend fun <T> CompletableFuture<T>.awaitResult(): T =
    suspendCancellableCoroutine { continuation ->
        whenComplete { value, error ->
            if (error == null) {
                continuation.resumeWith(Result.success(value))
            } else {
                continuation.resumeWith(Result.failure(error.cause ?: error))
            }
        }
        continuation.invokeOnCancellation { cancel(true) }
    }
