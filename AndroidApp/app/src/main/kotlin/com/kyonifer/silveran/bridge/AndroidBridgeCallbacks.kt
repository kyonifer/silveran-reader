package com.kyonifer.silveran.bridge

import androidx.annotation.Keep

@Keep
object AndroidBridgeCallbacks {
    @Volatile
    private var listener: (() -> Unit)? = null

    fun observe(onChange: () -> Unit) {
        listener = onChange
    }

    fun clear() {
        listener = null
    }

    @JvmStatic
    fun librarySnapshotDidChange() {
        listener?.invoke()
    }
}
