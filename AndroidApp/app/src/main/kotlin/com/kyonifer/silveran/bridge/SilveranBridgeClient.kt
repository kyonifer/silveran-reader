package com.kyonifer.silveran.bridge

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.util.LruCache
import com.kyonifer.silveran.model.AppSettings
import com.kyonifer.silveran.model.AudiobookChapter
import com.kyonifer.silveran.model.AudiobookPlayerState
import com.kyonifer.silveran.model.Book
import com.kyonifer.silveran.model.BookDetails
import com.kyonifer.silveran.model.BookID
import com.kyonifer.silveran.model.BookMedia
import com.kyonifer.silveran.model.DownloadOperation
import com.kyonifer.silveran.model.DownloadUpdate
import com.kyonifer.silveran.model.HomeSection
import com.kyonifer.silveran.model.LibrarySnapshot
import com.kyonifer.silveran.model.ReaderOpenResult
import com.kyonifer.silveran.model.ReaderState
import com.kyonifer.silveran.model.ReaderTocEntry
import com.kyonifer.silveran.model.ServerPosition
import com.kyonifer.silveran.model.SourceStatusUpdate
import com.kyonifer.silveran.model.StorytellerSettings
import com.kyonifer.silveran.platform.AndroidAudioPlayerBridge
import com.kyonifer.silveran.platform.AndroidNetworkMonitor
import com.kyonifer.silveran.platform.AndroidSecureStore
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import org.json.JSONArray
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

    @Volatile
    private var bootstrapped = false

    suspend fun bootstrap() {
        AndroidSecureStore.initialize(applicationContext)
        AndroidAudioPlayerBridge.initialize(applicationContext)
        val networkAvailable = AndroidNetworkMonitor.isNetworkAvailable(applicationContext)
        SilveranAndroidBridge.bootstrapAndroid(filesDirectory).awaitResult()
        SilveranAndroidBridge.androidNetworkAvailabilityDidChange(networkAvailable).awaitResult()
        AndroidNetworkMonitor.start(applicationContext)
        bootstrapped = true
        appDidBecomeActive()
    }

    fun appDidBecomeActive() {
        if (!bootstrapped) return
        SilveranAndroidBridge.androidAppDidBecomeActive().whenComplete { _, error ->
            if (error != null) Log.e("SilveranNetwork", "Could not activate source", error)
        }
    }

    fun appDidEnterBackground() {
        if (!bootstrapped) return
        SilveranAndroidBridge.androidAppDidEnterBackground().whenComplete { _, error ->
            if (error != null) Log.e("SilveranNetwork", "Could not deactivate source", error)
        }
    }

    suspend fun observeLibraryChanges(onChange: () -> Unit) {
        AndroidBridgeCallbacks.observe(this, onChange)
        SilveranAndroidBridge.startLibraryObservation().awaitResult()
    }

    fun observeAudiobookChanges(onChange: (AudiobookPlayerState?) -> Unit) {
        AndroidBridgeCallbacks.observeAudiobook(this) { payload ->
            onChange(payload.takeIf(String::isNotBlank)?.let(::parseAudiobookState))
        }
    }

    fun observeDownloadChanges(onChange: (List<DownloadUpdate>) -> Unit) {
        AndroidBridgeCallbacks.observeDownloads(this) { payload ->
            onChange(parseDownloadUpdates(payload))
        }
    }

    fun observeSourceStatusChanges(onChange: (SourceStatusUpdate) -> Unit) {
        AndroidBridgeCallbacks.observeSourceStatus(this) { payload ->
            val status = JSONObject(payload)
            if (status.optString("status") == "connected") missingCovers.clear()
            onChange(
                SourceStatusUpdate(
                    status = status.optString("status", "disconnected"),
                    message = status.optionalString("message"),
                )
            )
        }
    }

    fun close() {
        AndroidBridgeCallbacks.clearObserver(this)
    }

    suspend fun storytellerSettings(): StorytellerSettings {
        val json = AndroidBridgeCallbacks.requestPayload { requestID ->
            SilveranAndroidBridge.storytellerSettingsJSON(requestID)
        }
        return withContext(Dispatchers.Default) { parseSettings(json) }
    }

    suspend fun appSettings(): AppSettings {
        val json = AndroidBridgeCallbacks.requestPayload { requestID ->
            SilveranAndroidBridge.appSettingsJSON(requestID)
        }
        return withContext(Dispatchers.Default) { parseAppSettings(json) }
    }

    suspend fun saveAppSettings(
        progressSyncIntervalSeconds: Double? = null,
        metadataRefreshIntervalSeconds: Double? = null,
        autoSyncToNewerServerPosition: Boolean? = null,
    ): AppSettings {
        val update = JSONObject().apply {
            progressSyncIntervalSeconds?.let { put("progressSyncIntervalSeconds", it) }
            metadataRefreshIntervalSeconds?.let { put("metadataRefreshIntervalSeconds", it) }
            autoSyncToNewerServerPosition?.let { put("autoSyncToNewerServerPosition", it) }
        }.toString()
        val json = AndroidBridgeCallbacks.requestPayload { requestID ->
            SilveranAndroidBridge.saveAppSettings(requestID, update)
        }
        return withContext(Dispatchers.Default) { parseAppSettings(json) }
    }

    private fun parseAppSettings(json: String): AppSettings {
        val obj = JSONObject(json)
        return AppSettings(
            progressSyncIntervalSeconds = obj.optDouble("progressSyncIntervalSeconds", 60.0),
            metadataRefreshIntervalSeconds = obj.optDouble(
                "metadataRefreshIntervalSeconds",
                300.0,
            ),
            autoSyncToNewerServerPosition = obj.optBoolean("autoSyncToNewerServerPosition"),
        )
    }

    suspend fun librarySnapshot(refresh: Boolean): LibrarySnapshot {
        if (refresh) missingCovers.clear()
        val json = AndroidBridgeCallbacks.requestPayload { requestID ->
            SilveranAndroidBridge.librarySnapshotJSON(requestID, refresh)
        }
        return withContext(Dispatchers.Default) { parseLibrary(json) }
    }

    suspend fun bookDetails(book: Book): BookDetails {
        val json = AndroidBridgeCallbacks.requestPayload { requestID ->
            SilveranAndroidBridge.bookDetailsJSON(
                requestID,
                book.id.uuid,
                book.id.sourceID,
            )
        }
        return withContext(Dispatchers.Default) {
            val details = JSONObject(json)
            BookDetails(
                version = details.optString("version"),
                description = details.optionalString("description"),
                publicationDateDisplay = details.optString("publicationDateDisplay"),
                createdAtDisplay = details.optString("createdAtDisplay"),
                updatedAtDisplay = details.optString("updatedAtDisplay"),
            )
        }
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

    suspend fun openAudiobook(book: Book) {
        openAudiobook(book.id)
    }

    suspend fun openAudiobook(bookID: BookID) {
        audiobookOperations.withLock {
            SilveranAndroidBridge.openAudiobook(
                bookID.uuid,
                bookID.sourceID,
            ).awaitResult()
        }
    }

    suspend fun closeAudiobook() {
        audiobookOperations.withLock {
            SilveranAndroidBridge.closeAudiobook().awaitResult()
        }
    }

    suspend fun controlAudiobook(
        command: String,
        value: Double = 0.0,
        text: String = "",
    ) {
        SilveranAndroidBridge.controlAudiobook(command, value, text).awaitResult()
    }

    suspend fun openReader(book: Book, mode: String): ReaderOpenResult {
        val json = AndroidBridgeCallbacks.requestPayload { requestID ->
            SilveranAndroidBridge.openReader(
                requestID,
                book.id.uuid,
                book.id.sourceID,
                mode,
            )
        }
        return withContext(Dispatchers.Default) { parseReaderOpenResult(json) }
    }

    suspend fun closeReader() {
        SilveranAndroidBridge.closeReader().awaitResult()
    }

    suspend fun readerControl(
        command: String,
        value: Double = 0.0,
        text: String = "",
    ) {
        SilveranAndroidBridge.readerControl(command, value, text).awaitResult()
    }

    // Called from the WebView's JavascriptInterface thread; fire-and-forget.
    fun readerMessageFromJS(name: String, body: String) {
        SilveranAndroidBridge.readerMessageFromJS(name, body)
    }

    fun registerReaderWebView(owner: Any, webView: android.webkit.WebView) {
        AndroidBridgeCallbacks.registerReaderWebView(owner, webView)
    }

    fun unregisterReaderWebView(owner: Any) {
        AndroidBridgeCallbacks.unregisterReaderWebView(owner)
    }

    fun observeReaderState(onChange: (ReaderState) -> Unit) {
        AndroidBridgeCallbacks.observeReaderState(this) { payload ->
            runCatching { parseReaderState(payload) }
                .getOrNull()
                ?.let(onChange)
        }
    }

    private fun parseReaderOpenResult(json: String): ReaderOpenResult {
        val obj = JSONObject(json)
        return ReaderOpenResult(
            readerPath = obj.getString("readerPath"),
            originalPath = obj.optString("originalPath"),
            hasAudioNarration = obj.optBoolean("hasAudioNarration"),
            title = obj.optString("title"),
        )
    }

    private fun parseReaderState(json: String): ReaderState {
        val obj = JSONObject(json)
        val tocArray = obj.optJSONArray("toc")
        val toc = buildList {
            if (tocArray != null) {
                for (index in 0 until tocArray.length()) {
                    val entry = tocArray.getJSONObject(index)
                    add(
                        ReaderTocEntry(
                            label = entry.optString("label"),
                            href = entry.optString("href"),
                            level = entry.optInt("level"),
                            sectionIndex = entry.optInt("sectionIndex"),
                        )
                    )
                }
            }
        }
        return ReaderState(
            title = obj.optString("title"),
            author = obj.optString("author"),
            hasAudioNarration = obj.optBoolean("hasAudioNarration"),
            toc = toc,
            selectedChapterId = obj.optionalInt("selectedChapterId"),
            bookFraction = obj.optionalDouble("bookFraction"),
            chapterFraction = obj.optionalDouble("chapterFraction"),
            chapterCurrentPage = obj.optionalInt("chapterCurrentPage"),
            chapterTotalPages = obj.optionalInt("chapterTotalPages"),
            isPlaying = obj.optBoolean("isPlaying"),
            playbackRate = obj.optDouble("playbackRate", 1.0),
            bookTimeRemaining = obj.optionalDouble("bookTimeRemaining"),
            chapterTimeRemaining = obj.optionalDouble("chapterTimeRemaining"),
            overlayToggleCount = obj.optInt("overlayToggleCount"),
            keepScreenOn = obj.optBoolean("keepScreenOn"),
        )
    }

    suspend fun cover(book: Book, audio: Boolean, width: Int, height: Int): Bitmap? {
        val cacheKey = CoverCacheKey(book.id, book.coverVersion, audio)
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

    fun cachedCover(book: Book, audio: Boolean): Bitmap? =
        coverBitmaps.get(CoverCacheKey(book.id, book.coverVersion, audio))

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
        var decoded = decodeCover(response.data, width, height)
        if (decoded == null && response.data.isNotEmpty()) {
            response = loadCoverResponse(book, audio, width, height, refresh = true)
            decoded = decodeCover(response.data, width, height)
        }
        if (decoded == null) {
            missingCovers.add(missingKey)
        } else {
            if (response.shouldPersist) {
                SilveranAndroidBridge.persistCoverBytes(
                    book.id.uuid,
                    book.id.sourceID,
                    audio,
                    response.data,
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
    ): CoverPayload =
        AndroidBridgeCallbacks.requestCover { requestID ->
            SilveranAndroidBridge.coverResponseBytes(
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

    private suspend fun decodeCover(bytes: ByteArray, width: Int, height: Int): Bitmap? =
        withContext(Dispatchers.Default) {
            if (bytes.isEmpty()) return@withContext null
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
                subtitle = item.optionalString("subtitle"),
                authors = item.optString("authors"),
                authorNames = item.stringList("authorNames"),
                narrators = item.stringList("narrators"),
                series = item.getJSONArray("series").let { series ->
                    List(series.length()) { seriesIndex ->
                        val value = series.getJSONObject(seriesIndex)
                        com.kyonifer.silveran.model.BookSeries(
                            name = value.getString("name"),
                            position = value.optionalDouble("position"),
                        )
                    }
                },
                tags = item.stringList("tags"),
                collections = item.stringList("collections"),
                description = item.optionalString("description"),
                language = item.optionalString("language"),
                publicationDateDisplay = item.optString("publicationDateDisplay"),
                createdAt = item.optionalString("createdAt"),
                createdAtDisplay = item.optString("createdAtDisplay"),
                updatedAtDisplay = item.optString("updatedAtDisplay"),
                rating = item.optionalDouble("rating"),
                progress = item.optDouble("progress", 0.0),
                pageCount = item.takeUnless { it.isNull("pageCount") }?.optInt("pageCount"),
                durationDisplay = item.optString("durationDisplay"),
                durationSeconds = item.optDouble("durationSeconds", 0.0),
                sortTitle = item.optString("sortTitle", item.getString("title")),
                sortAuthor = item.optString("sortAuthor"),
                sortNarrator = item.optString("sortNarrator"),
                sortSeriesName = item.optString("sortSeriesName"),
                sortSeriesPosition = item.optDouble("sortSeriesPosition", Double.MAX_VALUE),
                sortAdded = item.optString("sortAdded"),
                sortLastRead = item.optString("sortLastRead"),
                sortPublicationDate = item.optString("sortPublicationDate"),
                publicationYear = item.optString("publicationYear"),
                status = item.optionalString("status"),
                fileSizeBytes = item.optLong("fileSizeBytes", 0L),
                coverVersion = item.optString("coverVersion"),
                media = List(mediaItems.length()) { mediaIndex ->
                    val media = mediaItems.getJSONObject(mediaIndex)
                    BookMedia(
                        category = media.getString("category"),
                        format = media.optionalString("format"),
                        pageCount = media.takeUnless { it.isNull("pageCount") }
                            ?.optInt("pageCount"),
                        durationDisplay = media.optString("durationDisplay"),
                        fileSizeDisplay = media.optString("fileSizeDisplay"),
                        status = media.optionalString("status"),
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

    private fun JSONObject.stringList(name: String): List<String> {
        val values = optJSONArray(name) ?: return emptyList()
        return List(values.length()) { values.getString(it) }
    }

    private companion object {
        // The activity and media service use separate clients but share one
        // Swift audiobook actor and Android audio backend.
        val audiobookOperations = Mutex()
    }
}

internal fun parseAudiobookState(json: String): AudiobookPlayerState {
    val root = JSONObject(json)
    val chapters = root.getJSONArray("chapters")
    val pending = root.optJSONObject("pendingServerPosition")
    return AudiobookPlayerState(
        bookID = BookID(
            sourceID = root.getString("sourceID"),
            uuid = root.getString("bookID"),
        ),
        title = root.getString("title"),
        author = root.getString("author"),
        isPlaying = root.getBoolean("isPlaying"),
        currentTime = root.getDouble("currentTime"),
        duration = root.getDouble("duration"),
        bookProgress = root.getDouble("bookProgress"),
        currentChapterID = root.optionalString("currentChapterID"),
        currentChapterIndex = root.optionalInt("currentChapterIndex"),
        chapterElapsed = root.getDouble("chapterElapsed"),
        chapterDuration = root.getDouble("chapterDuration"),
        chapterProgress = root.getDouble("chapterProgress"),
        playbackRate = root.getDouble("playbackRate"),
        volume = root.getDouble("volume"),
        chapters = List(chapters.length()) { index ->
            val chapter = chapters.getJSONObject(index)
            AudiobookChapter(
                id = chapter.getString("id"),
                title = chapter.getString("title"),
                duration = chapter.getDouble("duration"),
            )
        },
        sleepTimerMode = root.optionalString("sleepTimerMode"),
        sleepTimerRemaining = root.optionalDouble("sleepTimerRemaining"),
        pendingServerPosition = pending?.let {
            ServerPosition(
                title = it.optionalString("title"),
                totalProgression = it.optionalDouble("totalProgression"),
            )
        },
    )
}

private fun parseDownloadUpdates(json: String): List<DownloadUpdate> {
    val updates = JSONArray(json)
    return List(updates.length()) { index ->
        val update = updates.getJSONObject(index)
        DownloadUpdate(
            operation = DownloadOperation(
                bookID = BookID(
                    sourceID = update.getString("sourceID"),
                    uuid = update.getString("bookID"),
                ),
                category = update.getString("category"),
            ),
            state = update.getString("state"),
            progress = update.optionalDouble("progress"),
        )
    }
}

private data class CoverCacheKey(
    val bookID: BookID,
    val coverVersion: String,
    val audio: Boolean,
)

private data class MissingCoverKey(
    val bookID: BookID,
    val coverVersion: String,
    val audio: Boolean,
)

private fun JSONObject.optionalString(name: String): String? =
    if (isNull(name)) null else optString(name).takeIf(String::isNotBlank)

private fun JSONObject.optionalDouble(name: String): Double? =
    if (isNull(name) || !has(name)) null else getDouble(name)

private fun JSONObject.optionalInt(name: String): Int? =
    if (isNull(name) || !has(name)) null else getInt(name)

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
