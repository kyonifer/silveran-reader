package com.kyonifer.silveran.bridge

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import com.kyonifer.silveran.model.Book
import com.kyonifer.silveran.model.LibrarySnapshot
import com.kyonifer.silveran.model.StorytellerSettings
import com.kyonifer.silveran.platform.AndroidSecureStore
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.json.JSONObject

class SilveranBridgeClient(context: Context) {
    private val applicationContext = context.applicationContext
    private val filesDirectory = context.filesDir.absolutePath
    // The client is ViewModel-owned, so loaded covers remain available for
    // the full UI session even when lazy-grid items leave composition.
    private val coverCache = ConcurrentHashMap<String, Bitmap>()

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

    suspend fun cover(book: Book, width: Int, height: Int): Bitmap? {
        val cacheKey = "${book.key}:${book.coverVersion}:$width:$height"
        coverCache.get(cacheKey)?.let { return it }

        val encoded = SilveranAndroidBridge.coverBase64(
            book.id,
            book.sourceID,
            book.coverVersion,
            width,
            height,
        ).awaitResult()
        val decoded = withContext(Dispatchers.Default) {
            val bytes = encoded.takeIf(String::isNotBlank)
                ?.let { Base64.decode(it, Base64.DEFAULT) }
                ?: return@withContext null
            decodeSampledBitmap(bytes, width, height)
        }
        decoded?.let { coverCache.put(cacheKey, it) }
        return decoded
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
                coverVersion = item.optString("coverVersion"),
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

private fun decodeSampledBitmap(bytes: ByteArray, requestedWidth: Int, requestedHeight: Int): Bitmap? {
    if (requestedWidth <= 0 || requestedHeight <= 0) return null

    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

    var sampleSize = 1
    val halfWidth = bounds.outWidth / 2
    val halfHeight = bounds.outHeight / 2
    while (halfWidth / sampleSize >= requestedWidth &&
        halfHeight / sampleSize >= requestedHeight
    ) {
        sampleSize *= 2
    }

    val options = BitmapFactory.Options().apply { inSampleSize = sampleSize }
    val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
    if (decoded.width <= requestedWidth && decoded.height <= requestedHeight) return decoded

    val scale = minOf(
        requestedWidth.toDouble() / decoded.width,
        requestedHeight.toDouble() / decoded.height,
    )
    val scaledWidth = maxOf(1, (decoded.width * scale).toInt())
    val scaledHeight = maxOf(1, (decoded.height * scale).toInt())
    val scaled = Bitmap.createScaledBitmap(decoded, scaledWidth, scaledHeight, true)
    if (scaled !== decoded) decoded.recycle()
    return scaled
}

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
