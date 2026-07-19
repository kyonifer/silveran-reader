package com.kyonifer.silveran.model

import java.io.Serializable

data class BookID(
    val sourceID: String,
    val uuid: String,
) : Serializable

data class Book(
    val id: BookID,
    val title: String,
    val authors: String,
    val description: String?,
    val createdAt: String?,
    val coverVersion: String,
    val media: List<BookMedia>,
) {
    val hasEbook: Boolean get() = media.any { it.category == "ebook" }
    val hasAudio: Boolean get() = media.any { it.category == "audio" }
    val hasReadaloud: Boolean get() = media.any { it.category == "synced" }
    val hasDownloadedMedia: Boolean get() = media.any(BookMedia::downloaded)
}

data class BookMedia(
    val category: String,
    val downloaded: Boolean,
    val removable: Boolean,
    val downloadState: String?,
    val downloadProgress: Double?,
)

data class LibrarySnapshot(
    val books: List<Book>,
    val homeSections: List<HomeSection>,
    val sourceStatus: String,
    val sourceMessage: String?,
)

data class HomeSection(
    val kind: String,
    val title: String,
    val bookIDs: List<BookID>,
)

data class DownloadOperation(
    val bookID: BookID,
    val category: String,
)

data class StorytellerSettings(
    val configured: Boolean = false,
    val sourceID: String? = null,
    val serverURL: String = "",
    val username: String = "",
    val connectionStatus: String = "notConfigured",
    val connectionMessage: String? = null,
)

data class AudiobookChapter(
    val id: String,
    val title: String,
    val duration: Double,
)

data class ServerPosition(
    val title: String?,
    val totalProgression: Double?,
)

data class AudiobookPlayerState(
    val bookID: BookID,
    val title: String,
    val author: String,
    val isPlaying: Boolean,
    val currentTime: Double,
    val duration: Double,
    val bookProgress: Double,
    val currentChapterID: String?,
    val currentChapterIndex: Int?,
    val chapterElapsed: Double,
    val chapterDuration: Double,
    val chapterProgress: Double,
    val playbackRate: Double,
    val volume: Double,
    val chapters: List<AudiobookChapter>,
    val sleepTimerMode: String?,
    val sleepTimerRemaining: Double?,
    val pendingServerPosition: ServerPosition?,
)
