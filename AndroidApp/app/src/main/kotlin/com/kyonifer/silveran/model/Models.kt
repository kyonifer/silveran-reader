package com.kyonifer.silveran.model

data class Book(
    val id: String,
    val sourceID: String,
    val title: String,
    val authors: String,
    val description: String?,
    val coverVersion: String,
    val media: List<BookMedia>,
) {
    val key: String = "$sourceID:$id"
    val hasEbook: Boolean get() = media.any { it.category == "ebook" }
    val hasAudio: Boolean get() = media.any { it.category == "audio" }
    val hasReadaloud: Boolean get() = media.any { it.category == "synced" }
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
    val sourceStatus: String,
    val sourceMessage: String?,
)

data class StorytellerSettings(
    val configured: Boolean = false,
    val sourceID: String? = null,
    val serverURL: String = "",
    val username: String = "",
    val connectionStatus: String = "notConfigured",
    val connectionMessage: String? = null,
)
