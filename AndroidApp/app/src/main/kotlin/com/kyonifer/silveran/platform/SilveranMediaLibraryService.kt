package com.kyonifer.silveran.platform

import android.app.PendingIntent
import android.content.Intent
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionError
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.kyonifer.silveran.MainActivity

/** Hosts Silveran's now-playing Player for system media clients and future Android Auto browsing. */
@OptIn(UnstableApi::class)
class SilveranMediaLibraryService : MediaLibraryService() {
    private var session: MediaLibrarySession? = null

    override fun onCreate() {
        super.onCreate()
        val sessionActivity = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        session = MediaLibrarySession.Builder(
            this,
            AndroidNowPlayingBridge.sessionPlayer(),
            libraryCallback,
        )
            .setSessionActivity(sessionActivity)
            .setMediaButtonPreferences(mediaButtonPreferences)
            .build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? =
        session

    override fun onDestroy() {
        session?.release()
        session = null
        super.onDestroy()
    }

    private companion object {
        const val ROOT_MEDIA_ID = "silveran-root"

        val rootMediaItem: MediaItem = MediaItem.Builder()
            .setMediaId(ROOT_MEDIA_ID)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle("Silveran")
                    .setIsBrowsable(true)
                    .setIsPlayable(false)
                    .build(),
            )
            .build()

        val libraryCallback = object : MediaLibrarySession.Callback {
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
                Futures.immediateFuture(
                    if (parentId == ROOT_MEDIA_ID) {
                        LibraryResult.ofItemList(emptyList(), params)
                    } else {
                        LibraryResult.ofError(SessionError.ERROR_BAD_VALUE, params)
                    },
                )
        }

        val mediaButtonPreferences = listOf(
            CommandButton.Builder(CommandButton.ICON_SKIP_BACK_15)
                .setDisplayName("Back 15 seconds")
                .setPlayerCommand(Player.COMMAND_SEEK_BACK)
                .build(),
            CommandButton.Builder(CommandButton.ICON_SKIP_FORWARD_15)
                .setDisplayName("Forward 15 seconds")
                .setPlayerCommand(Player.COMMAND_SEEK_FORWARD)
                .build(),
        )
    }
}
