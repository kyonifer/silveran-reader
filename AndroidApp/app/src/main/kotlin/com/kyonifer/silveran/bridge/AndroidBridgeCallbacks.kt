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
    private val payloadRequests = ConcurrentHashMap<String, CompletableDeferred<String>>()

    fun observe(onChange: () -> Unit) {
        listener = onChange
    }

    fun clearObserver() {
        listener = null
        audiobookListener = null
    }

    fun observeAudiobook(onChange: (String) -> Unit) {
        audiobookListener = onChange
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

    @JvmStatic
    fun bridgeRequestDidComplete(requestID: String, payload: String, error: String) {
        val request = payloadRequests.remove(requestID) ?: return
        if (error.isEmpty()) {
            request.complete(payload)
        } else {
            request.completeExceptionally(IllegalStateException(error))
        }
    }
}
