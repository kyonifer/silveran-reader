package com.kyonifer.silveran.bridge

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.util.LruCache
import com.kyonifer.silveran.model.Book
import com.kyonifer.silveran.model.BookID
import com.kyonifer.silveran.model.BookMedia
import com.kyonifer.silveran.model.HomeSection
import com.kyonifer.silveran.model.LibrarySnapshot
import com.kyonifer.silveran.model.StorytellerSettings
import com.kyonifer.silveran.platform.AndroidSecureStore
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONObject

class SilveranBridgeClient(context: Context) {
    private val applicationContext = context.applicationContext
    private val filesDirectory = context.filesDir.absolutePath
    // The Swift core owns persistent cover bytes. This cache only bounds
    // decoded Android bitmaps used by the currently active UI session.
    private val coverBitmaps = object : LruCache<CoverCacheKey, Bitmap>(bitmapCacheSizeKilobytes()) {
        override fun sizeOf(key: CoverCacheKey, value: Bitmap): Int =
            maxOf(1, value.allocationByteCount / 1024)
    }
    private val missingCovers = ConcurrentHashMap.newKeySet<MissingCoverKey>()
    private val coverRequests = Semaphore(4)

    suspend fun bootstrap() {
        AndroidSecureStore.initialize(applicationContext)
        SilveranAndroidBridge.bootstrapAndroid(filesDirectory).awaitResult()
    }

    suspend fun observeLibraryChanges(onChange: () -> Unit) {
        AndroidBridgeCallbacks.observe(onChange)
        SilveranAndroidBridge.startLibraryObservation().awaitResult()
    }

    fun close() {
        AndroidBridgeCallbacks.clear()
    }

    suspend fun storytellerSettings(): StorytellerSettings {
        val json = AndroidBridgeCallbacks.requestPayload { requestID ->
            SilveranAndroidBridge.storytellerSettingsJSON(requestID)
        }
        return withContext(Dispatchers.Default) { parseSettings(json) }
    }

    suspend fun librarySnapshot(refresh: Boolean): LibrarySnapshot {
        if (refresh) missingCovers.clear()
        val json = AndroidBridgeCallbacks.requestPayload { requestID ->
            SilveranAndroidBridge.librarySnapshotJSON(requestID, refresh)
        }
        return withContext(Dispatchers.Default) { parseLibrary(json) }
    }

    suspend fun download(book: Book, category: String) {
        SilveranAndroidBridge.downloadBook(
            book.id.uuid,
            book.id.sourceID,
            category,
        ).awaitResult()
    }

    suspend fun cancelDownload(book: Book, category: String) {
        SilveranAndroidBridge.cancelBookDownload(
            book.id.uuid,
            book.id.sourceID,
            category,
        ).awaitResult()
    }

    suspend fun deleteDownload(book: Book, category: String) {
        SilveranAndroidBridge.deleteBookDownload(
            book.id.uuid,
            book.id.sourceID,
            category,
        ).awaitResult()
    }

    suspend fun cover(book: Book, audio: Boolean, width: Int, height: Int): Bitmap? {
        val cacheKey = CoverCacheKey(book.id, book.coverVersion, audio, width, height)
        val missingKey = MissingCoverKey(book.id, book.coverVersion, audio)
        coverBitmaps.get(cacheKey)?.let { return it }
        if (missingKey in missingCovers) return null

        return coverRequests.withPermit {
            // Once a Swift request starts, let it finish and populate the cache.
            // Cancellation only prevents offscreen requests that are still queued.
            withContext(NonCancellable) {
                coverBitmaps.get(cacheKey)
                    ?: loadCover(book, audio, width, height, cacheKey, missingKey)
            }
        }
    }

    private suspend fun loadCover(
        book: Book,
        audio: Boolean,
        width: Int,
        height: Int,
        cacheKey: CoverCacheKey,
        missingKey: MissingCoverKey,
    ): Bitmap? {
        if (missingKey in missingCovers) return null

        var response = loadCoverResponse(book, audio, width, height, refresh = false)
        var decoded = decodeCover(response.dataBase64, width, height)
        if (decoded == null && response.dataBase64.isNotBlank()) {
            response = loadCoverResponse(book, audio, width, height, refresh = true)
            decoded = decodeCover(response.dataBase64, width, height)
        }
        if (decoded == null) {
            missingCovers.add(missingKey)
        } else {
            if (response.shouldPersist) {
                SilveranAndroidBridge.persistCoverBase64(
                    book.id.uuid,
                    book.id.sourceID,
                    audio,
                    response.dataBase64,
                ).awaitResult()
            }
            coverBitmaps.put(cacheKey, decoded)
        }
        return decoded
    }

    private suspend fun loadCoverResponse(
        book: Book,
        audio: Boolean,
        width: Int,
        height: Int,
        refresh: Boolean,
    ): CoverResponse {
        val json = AndroidBridgeCallbacks.requestPayload { requestID ->
            SilveranAndroidBridge.coverResponseJSON(
                requestID,
                book.id.uuid,
                book.id.sourceID,
                book.coverVersion,
                audio,
                width,
                height,
                refresh,
            )
        }
        return withContext(Dispatchers.Default) {
            val response = JSONObject(json)
            CoverResponse(
                dataBase64 = response.getString("dataBase64"),
                shouldPersist = response.getBoolean("shouldPersist"),
            )
        }
    }

    private suspend fun decodeCover(encoded: String, width: Int, height: Int): Bitmap? =
        withContext(Dispatchers.Default) {
            val bytes = encoded.takeIf(String::isNotBlank)
                ?.let { Base64.decode(it, Base64.DEFAULT) }
                ?: return@withContext null
            decodeSampledBitmap(bytes, width, height)
        }

    suspend fun saveStorytellerSettings(
        serverURL: String,
        username: String,
        password: String,
    ): StorytellerSettings {
        val json = AndroidBridgeCallbacks.requestPayload { requestID ->
            SilveranAndroidBridge.saveStorytellerSettings(
                requestID,
                serverURL,
                username,
                password,
            )
        }
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
            val mediaItems = item.getJSONArray("media")
            Book(
                id = BookID(
                    sourceID = item.getString("sourceID"),
                    uuid = item.getString("id"),
                ),
                title = item.getString("title"),
                authors = item.optString("authors"),
                description = item.optionalString("description"),
                createdAt = item.optionalString("createdAt"),
                coverVersion = item.optString("coverVersion"),
                media = List(mediaItems.length()) { mediaIndex ->
                    val media = mediaItems.getJSONObject(mediaIndex)
                    BookMedia(
                        category = media.getString("category"),
                        downloaded = media.getBoolean("downloaded"),
                        removable = media.getBoolean("removable"),
                        downloadState = media.optionalString("downloadState"),
                        downloadProgress = media.optionalDouble("downloadProgress"),
                    )
                },
            )
        }
        return LibrarySnapshot(
            books = books,
            homeSections = root.getJSONArray("homeSections").let { sections ->
                List(sections.length()) { index ->
                    val section = sections.getJSONObject(index)
                    val bookIDs = section.getJSONArray("bookIDs")
                    HomeSection(
                        kind = section.getString("kind"),
                        title = section.getString("title"),
                        bookIDs = List(bookIDs.length()) { bookIndex ->
                            val bookID = bookIDs.getJSONObject(bookIndex)
                            BookID(
                                sourceID = bookID.getString("sourceID"),
                                uuid = bookID.getString("uuid"),
                            )
                        },
                    )
                }
            },
            sourceStatus = root.optString("sourceStatus", "notConfigured"),
            sourceMessage = root.optionalString("sourceMessage"),
        )
    }
}

private data class CoverCacheKey(
    val bookID: BookID,
    val coverVersion: String,
    val audio: Boolean,
    val width: Int,
    val height: Int,
)

private data class MissingCoverKey(
    val bookID: BookID,
    val coverVersion: String,
    val audio: Boolean,
)

private data class CoverResponse(
    val dataBase64: String,
    val shouldPersist: Boolean,
)

private fun JSONObject.optionalString(name: String): String? =
    if (isNull(name)) null else optString(name).takeIf(String::isNotBlank)

private fun JSONObject.optionalDouble(name: String): Double? =
    if (isNull(name) || !has(name)) null else getDouble(name)

private fun bitmapCacheSizeKilobytes(): Int =
    maxOf(1, (Runtime.getRuntime().maxMemory() / 8 / 1024).toInt())

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

internal suspend fun <T> CompletableFuture<T>.awaitResult(): T =
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
