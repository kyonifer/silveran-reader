package com.kyonifer.silveran.model

data class Book(
    val id: String,
    val sourceID: String,
    val title: String,
    val authors: String,
    val description: String?,
    val coverVersion: String,
    val hasEbook: Boolean,
    val hasAudio: Boolean,
    val ebookDownloaded: Boolean,
    val audioDownloaded: Boolean,
    val ebookDownloadState: String?,
    val audioDownloadState: String?,
    val ebookDownloadProgress: Double?,
    val audioDownloadProgress: Double?,
) {
    val key: String = "$sourceID:$id"
}

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
