package com.kyonifer.silveran.platform

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionError
import androidx.media3.session.SessionResult
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import com.kyonifer.silveran.MainActivity
import com.kyonifer.silveran.R
import com.kyonifer.silveran.bridge.SilveranBridgeClient
import com.kyonifer.silveran.model.Book
import com.kyonifer.silveran.model.BookID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.resume
import kotlin.math.abs
import kotlin.math.roundToInt

/** Hosts Silveran's now-playing Player and downloaded audiobook catalog for Android Auto. */
@OptIn(UnstableApi::class)
class SilveranMediaLibraryService : MediaLibraryService() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val bootstrapMutex = Mutex()
    private var session: MediaLibrarySession? = null
    private var bootstrapped = false
    private lateinit var client: SilveranBridgeClient

    private val playbackRateListener = object : Player.Listener {
        override fun onPlaybackParametersChanged(playbackParameters: PlaybackParameters) {
            session?.setMediaButtonPreferences(
                mediaButtonPreferences(playbackParameters.speed.toDouble()),
            )
        }
    }

    override fun onCreate() {
        super.onCreate()
        client = SilveranBridgeClient(applicationContext)
        val sessionActivity = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val player = AndroidNowPlayingBridge.sessionPlayer()
        session = MediaLibrarySession.Builder(this, player, libraryCallback)
            .setSessionActivity(sessionActivity)
            .setMediaButtonPreferences(
                mediaButtonPreferences(player.playbackParameters.speed.toDouble()),
            )
            .setPeriodicPositionUpdateEnabled(false)
            .build()
        player.addListener(playbackRateListener)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? =
        session

    override fun onDestroy() {
        session?.player?.removeListener(playbackRateListener)
        session?.release()
        session = null
        serviceScope.cancel()
        super.onDestroy()
    }

    private val libraryCallback = object : MediaLibrarySession.Callback {
        override fun onConnect(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
        ): MediaSession.ConnectionResult {
            val sessionCommands =
                MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS
                    .buildUpon()
                    .add(cyclePlaybackRateCommand)
                    .build()
            return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                .setAvailableSessionCommands(sessionCommands)
                .build()
        }

        override fun onGetLibraryRoot(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<MediaItem>> =
            Futures.immediateFuture(LibraryResult.ofItem(rootMediaItem, params))

        override fun onGetChildren(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            parentId: String,
            page: Int,
            pageSize: Int,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> =
            when (parentId) {
                ROOT_MEDIA_ID -> Futures.immediateFuture(
                    LibraryResult.ofItemList(
                        listOf(audiobooksMediaItem).requestedPage(page, pageSize),
                        params,
                    ),
                )
                AUDIOBOOKS_MEDIA_ID -> serviceFuture {
                    LibraryResult.ofItemList(
                        downloadedAudiobooks()
                            .map(Book::asAndroidAutoMediaItem)
                            .requestedPage(page, pageSize),
                        params,
                    )
                }
                else -> Futures.immediateFuture(
                    LibraryResult.ofError(SessionError.ERROR_BAD_VALUE, params),
                )
            }

        override fun onGetItem(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            mediaId: String,
        ): ListenableFuture<LibraryResult<MediaItem>> =
            when (mediaId) {
                ROOT_MEDIA_ID -> Futures.immediateFuture(
                    LibraryResult.ofItem(rootMediaItem, null),
                )
                AUDIOBOOKS_MEDIA_ID -> Futures.immediateFuture(
                    LibraryResult.ofItem(audiobooksMediaItem, null),
                )
                else -> serviceFuture {
                    val bookID = bookIDFromMediaId(mediaId)
                    val book = bookID?.let { id ->
                        downloadedAudiobooks().firstOrNull { it.id == id }
                    }
                    if (book == null) {
                        LibraryResult.ofError(SessionError.ERROR_BAD_VALUE)
                    } else {
                        LibraryResult.ofItem(book.asAndroidAutoMediaItem(), null)
                    }
                }
            }

        override fun onSetMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: List<MediaItem>,
            startIndex: Int,
            startPositionMs: Long,
        ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> =
            serviceFuture {
                val requestedID = mediaItems.singleOrNull()?.mediaId
                    ?: throw IllegalArgumentException("Expected one Silveran audiobook")
                val bookID = bookIDFromMediaId(requestedID)
                    ?: throw IllegalArgumentException("Invalid Silveran audiobook ID")
                val book = downloadedAudiobooks().firstOrNull { it.id == bookID }
                    ?: throw IllegalArgumentException("Audiobook is not downloaded")

                client.openAudiobook(book.id)
                awaitNowPlayingCommands()
                MediaSession.MediaItemsWithStartPosition(
                    listOf(book.asAndroidAutoMediaItem()),
                    0,
                    0L,
                )
            }

        override fun onCustomCommand(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            customCommand: SessionCommand,
            args: Bundle,
        ): ListenableFuture<SessionResult> {
            if (customCommand.customAction != CYCLE_PLAYBACK_RATE_ACTION) {
                return Futures.immediateFuture(
                    SessionResult(SessionResult.RESULT_ERROR_NOT_SUPPORTED),
                )
            }
            return serviceFuture {
                ensureBootstrapped()
                client.controlAudiobook("cyclePlaybackRate")
                SessionResult(SessionResult.RESULT_SUCCESS)
            }
        }
    }

    private suspend fun downloadedAudiobooks(): List<Book> {
        ensureBootstrapped()
        return client.librarySnapshot(refresh = false).books
            .filter { book ->
                book.media.any { media -> media.category == AUDIO_CATEGORY && media.downloaded }
            }
            .sortedWith(
                compareBy<Book, String>(String.CASE_INSENSITIVE_ORDER) { it.title }
                    .thenBy { it.id.uuid },
            )
    }

    private suspend fun ensureBootstrapped() {
        if (bootstrapped) return
        bootstrapMutex.withLock {
            if (!bootstrapped) {
                client.bootstrap()
                bootstrapped = true
            }
        }
    }

    private suspend fun awaitNowPlayingCommands() {
        // Swift's presenter posts its configure/update calls to this looper.
        // This barrier makes them visible before Media3 evaluates its follow-up play.
        suspendCancellableCoroutine { continuation ->
            mainHandler.post {
                if (continuation.isActive) continuation.resume(Unit)
            }
        }
        check(session?.player?.isCommandAvailable(Player.COMMAND_PLAY_PAUSE) == true) {
            "Silveran audiobook commands were not installed"
        }
    }

    private fun <T> serviceFuture(operation: suspend () -> T): ListenableFuture<T> {
        val future = SettableFuture.create<T>()
        serviceScope.launch {
            try {
                future.set(operation())
            } catch (_: CancellationException) {
                future.cancel(false)
            } catch (error: Throwable) {
                future.setException(error)
            }
        }
        return future
    }

    private val speedIcons: List<Pair<Int, Int>> by lazy {
        val hundredths = resources.getIntArray(R.array.speed_icon_hundredths)
        val drawables = resources.obtainTypedArray(R.array.speed_icon_drawables)
        try {
            hundredths.mapIndexed { index, value ->
                value to drawables.getResourceId(index, 0)
            }
        } finally {
            drawables.recycle()
        }
    }

    private fun speedIconButton(playbackRate: Double): CommandButton.Builder {
        val hundredths = (playbackRate * 100).roundToInt()
        val iconResId = speedIcons
            .minByOrNull { abs(it.first - hundredths) }
            ?.second
            ?.takeIf { it != 0 }
            ?: return CommandButton.Builder(CommandButton.ICON_PLAYBACK_SPEED)
        return CommandButton.Builder(CommandButton.ICON_UNDEFINED).setCustomIconResId(iconResId)
    }

    private fun mediaButtonPreferences(playbackRate: Double): List<CommandButton> = listOf(
        CommandButton.Builder(CommandButton.ICON_SKIP_BACK_15)
            .setDisplayName("Back 15 seconds")
            .setPlayerCommand(Player.COMMAND_SEEK_BACK)
            .build(),
        CommandButton.Builder(CommandButton.ICON_SKIP_FORWARD_15)
            .setDisplayName("Forward 15 seconds")
            .setPlayerCommand(Player.COMMAND_SEEK_FORWARD)
            .build(),
        speedIconButton(playbackRate)
            .setDisplayName("Playback speed")
            .setSessionCommand(cyclePlaybackRateCommand)
            .setSlots(CommandButton.SLOT_OVERFLOW)
            .build(),
    )

    private companion object {
        const val CYCLE_PLAYBACK_RATE_ACTION =
            "com.kyonifer.silveran.action.CYCLE_PLAYBACK_RATE"
        val cyclePlaybackRateCommand = SessionCommand(CYCLE_PLAYBACK_RATE_ACTION, Bundle.EMPTY)
    }
}

private const val ROOT_MEDIA_ID = "silveran-root"
private const val AUDIOBOOKS_MEDIA_ID = "silveran-audiobooks"
private const val MEDIA_ID_SCHEME = "silveran"
private const val AUDIOBOOK_MEDIA_ID_AUTHORITY = "audiobook"
private const val AUDIO_CATEGORY = "audio"

private val rootMediaItem: MediaItem = MediaItem.Builder()
    .setMediaId(ROOT_MEDIA_ID)
    .setMediaMetadata(
        MediaMetadata.Builder()
            .setTitle("Silveran")
            .setIsBrowsable(true)
            .setIsPlayable(false)
            .build(),
    )
    .build()

private val audiobooksMediaItem: MediaItem = MediaItem.Builder()
    .setMediaId(AUDIOBOOKS_MEDIA_ID)
    .setMediaMetadata(
        MediaMetadata.Builder()
            .setTitle("Downloaded audiobooks")
            .setIsBrowsable(true)
            .setIsPlayable(false)
            .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_AUDIO_BOOKS)
            .build(),
    )
    .build()

private fun Book.asAndroidAutoMediaItem(): MediaItem =
    MediaItem.Builder()
        .setMediaId(
            Uri.Builder()
                .scheme(MEDIA_ID_SCHEME)
                .authority(AUDIOBOOK_MEDIA_ID_AUTHORITY)
                .appendPath(id.sourceID)
                .appendPath(id.uuid)
                .build()
                .toString(),
        )
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(title)
                .setArtist(authors.takeIf(String::isNotBlank))
                .setIsBrowsable(false)
                .setIsPlayable(true)
                .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK)
                .build(),
        )
        .build()

private fun bookIDFromMediaId(mediaId: String): BookID? {
    val uri = Uri.parse(mediaId)
    if (uri.scheme != MEDIA_ID_SCHEME || uri.authority != AUDIOBOOK_MEDIA_ID_AUTHORITY) {
        return null
    }
    val segments = uri.pathSegments
    if (segments.size != 2 || segments.any(String::isBlank)) return null
    return BookID(sourceID = segments[0], uuid = segments[1])
}

private fun <T> List<T>.requestedPage(page: Int, pageSize: Int): List<T> {
    if (page < 0 || pageSize <= 0) return emptyList()
    val start = page.toLong() * pageSize
    if (start >= size) return emptyList()
    val end = minOf(size.toLong(), start + pageSize).toInt()
    return subList(start.toInt(), end)
}
