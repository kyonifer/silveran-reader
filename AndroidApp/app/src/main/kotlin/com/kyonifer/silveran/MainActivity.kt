package com.kyonifer.silveran

import android.app.Activity
import android.os.Bundle
import android.util.TypedValue
import android.widget.ScrollView
import android.widget.TextView
import com.kyonifer.silveran.bridge.SilveranAndroidBridge
import com.kyonifer.silveran.platform.AndroidSecureStore
import java.io.File
import kotlin.concurrent.thread

class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val text = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setPadding(32, 32, 32, 32)
            typeface = android.graphics.Typeface.MONOSPACE
            setText("Calling SilveranKit...")
        }
        setContentView(ScrollView(this).apply { addView(text) })

        thread {
            val output = StringBuilder()
            try {
                AndroidSecureStore.initialize(applicationContext)
                SilveranAndroidBridge.bootstrapAndroid(filesDir.absolutePath)
                output.appendLine(SilveranAndroidBridge.coreVersion())
                output.appendLine()

                val epub = File(cacheDir, "moby-dick.epub")
                assets.open("moby-dick.epub").use { input ->
                    epub.outputStream().use { input.copyTo(it) }
                }
                output.appendLine("Parsing ${epub.name} via SilveranKit:")
                output.appendLine(SilveranAndroidBridge.extractBookMetadata(epub.absolutePath))
            } catch (t: Throwable) {
                output.appendLine("FAILED: $t")
            }
            android.util.Log.i("SilveranApp", output.toString())
            runOnUiThread { text.text = output.toString() }
        }
    }
}
