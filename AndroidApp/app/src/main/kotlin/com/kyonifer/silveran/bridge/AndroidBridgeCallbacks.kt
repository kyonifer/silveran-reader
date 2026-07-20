package com.kyonifer.silveran.bridge

import androidx.annotation.Keep
import com.kyonifer.silveran.platform.AndroidNowPlayingBridge
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred

@Keep
object AndroidBridgeCallbacks {
    private class Registration<T>(val owner: Any, val callback: T)

    @Volatile
    private var listener: Registration<() -> Unit>? = null
    @Volatile
    private var audiobookListener: Registration<(String) -> Unit>? = null
    @Volatile
    private var downloadListener: Registration<(String) -> Unit>? = null
    @Volatile
    private var sourceStatusListener: Registration<(String) -> Unit>? = null
    private val payloadRequests = ConcurrentHashMap<String, CompletableDeferred<String>>()
    private val coverRequests = ConcurrentHashMap<String, CompletableDeferred<CoverPayload>>()

    fun observe(owner: Any, onChange: () -> Unit) {
        listener = Registration(owner, onChange)
    }

    // A stale owner (an already-replaced ViewModel's client) must not tear down
    // registrations that a newer owner has since installed.
    fun clearObserver(owner: Any) {
        if (listener?.owner === owner) listener = null
        if (audiobookListener?.owner === owner) audiobookListener = null
        if (downloadListener?.owner === owner) downloadListener = null
        if (sourceStatusListener?.owner === owner) sourceStatusListener = null
    }

    fun observeAudiobook(owner: Any, onChange: (String) -> Unit) {
        audiobookListener = Registration(owner, onChange)
    }

    fun observeDownloads(owner: Any, onChange: (String) -> Unit) {
        downloadListener = Registration(owner, onChange)
    }

    fun observeSourceStatus(owner: Any, onChange: (String) -> Unit) {
        sourceStatusListener = Registration(owner, onChange)
    }

    @JvmStatic
    fun librarySnapshotDidChange() {
        listener?.callback?.invoke()
    }

    @JvmStatic
    fun audiobookStateDidChange(payload: String) {
        AndroidNowPlayingBridge.updateAudiobookState(payload)
        audiobookListener?.callback?.invoke(payload)
    }

    @JvmStatic
    fun downloadStateDidChange(payload: String) {
        downloadListener?.callback?.invoke(payload)
    }

    @JvmStatic
    fun sourceStatusDidChange(payload: String) {
        sourceStatusListener?.callback?.invoke(payload)
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
