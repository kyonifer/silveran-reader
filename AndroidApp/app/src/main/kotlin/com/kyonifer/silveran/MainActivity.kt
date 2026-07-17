package com.kyonifer.silveran

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ViewModelProvider
import com.kyonifer.silveran.ui.SilveranApp
import com.kyonifer.silveran.ui.SilveranViewModel
import java.io.File

class MainActivity : ComponentActivity() {
    companion object {
        private var didCleanDownloadTemps = false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!didCleanDownloadTemps) {
            cleanupAbandonedSwiftDownloads(cacheDir)
            didCleanDownloadTemps = true
        }
        enableEdgeToEdge()

        val viewModel = ViewModelProvider(
            this,
            SilveranViewModel.factory(applicationContext),
        )[SilveranViewModel::class.java]

        setContent { SilveranApp(viewModel) }
    }
}

private val swiftDownloadTempName =
    Regex("""^[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(?:\.tmp)?$""")

private fun cleanupAbandonedSwiftDownloads(cacheDirectory: File) {
    // FoundationNetworking leaves UUID temp files after cancellation or process death.
    cacheDirectory.listFiles()?.forEach { file ->
        if (file.isFile && swiftDownloadTempName.matches(file.name)) {
            file.delete()
        }
    }
}
