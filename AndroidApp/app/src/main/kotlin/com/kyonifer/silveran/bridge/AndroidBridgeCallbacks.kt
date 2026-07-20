package com.kyonifer.silveran.bridge

import androidx.annotation.Keep
import com.kyonifer.silveran.platform.AndroidNowPlayingBridge
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred

@Keep
object AndroidBridgeCallbacks {
    @Volatile
    private var listener: (() -> Unit)? = null
    @Volatile
    private var audiobookListener: ((String) -> Unit)? = null
    @Volatile
    private var downloadListener: ((String) -> Unit)? = null
    @Volatile
    private var sourceStatusListener: ((String) -> Unit)? = null
    private val payloadRequests = ConcurrentHashMap<String, CompletableDeferred<String>>()
    private val coverRequests = ConcurrentHashMap<String, CompletableDeferred<CoverPayload>>()

    fun observe(onChange: () -> Unit) {
        listener = onChange
    }

    fun clearObserver() {
        listener = null
        audiobookListener = null
        downloadListener = null
        sourceStatusListener = null
    }

    fun observeAudiobook(onChange: (String) -> Unit) {
        audiobookListener = onChange
    }

    fun observeDownloads(onChange: (String) -> Unit) {
        downloadListener = onChange
    }

    fun observeSourceStatus(onChange: (String) -> Unit) {
        sourceStatusListener = onChange
    }

    @JvmStatic
    fun librarySnapshotDidChange() {
        listener?.invoke()
    }

    @JvmStatic
    fun audiobookStateDidChange(payload: String) {
        AndroidNowPlayingBridge.updateAudiobookState(payload)
        audiobookListener?.invoke(payload)
    }

    @JvmStatic
    fun downloadStateDidChange(payload: String) {
        downloadListener?.invoke(payload)
    }

    @JvmStatic
    fun sourceStatusDidChange(payload: String) {
        sourceStatusListener?.invoke(payload)
    }

    suspend fun requestPayload(start: (String) -> CompletableFuture<Void>): String {
        val requestID = UUID.randomUUID().toString()
        val result = CompletableDeferred<String>()
        check(payloadRequests.putIfAbsent(requestID, result) == null)
        return try {
            start(requestID).awaitResult()
            result.await()
        } finally {
            payloadRequests.remove(requestID, result)
        }
    }

    internal suspend fun requestCover(start: (String) -> CompletableFuture<Void>): CoverPayload {
        val requestID = UUID.randomUUID().toString()
        val result = CompletableDeferred<CoverPayload>()
        check(coverRequests.putIfAbsent(requestID, result) == null)
        return try {
            start(requestID).awaitResult()
            result.await()
        } finally {
            coverRequests.remove(requestID, result)
        }
    }

    @JvmStatic
    fun bridgeRequestDidComplete(requestID: String, payload: String, error: String) {
        val request = payloadRequests.remove(requestID) ?: return
        if (error.isEmpty()) {
            request.complete(payload)
        } else {
            request.completeExceptionally(IllegalStateException(error))
        }
    }

    @JvmStatic
    fun coverRequestDidComplete(
        requestID: String,
        data: ByteArray,
        shouldPersist: Boolean,
        error: String,
    ) {
        val request = coverRequests.remove(requestID) ?: return
        if (error.isEmpty()) {
            request.complete(CoverPayload(data, shouldPersist))
        } else {
            request.completeExceptionally(IllegalStateException(error))
        }
    }
}

internal data class CoverPayload(
    val data: ByteArray,
    val shouldPersist: Boolean,
)
