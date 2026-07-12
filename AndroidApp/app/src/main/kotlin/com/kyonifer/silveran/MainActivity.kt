package com.kyonifer.silveran

import android.os.Bundle
import android.system.Os
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ViewModelProvider
import com.kyonifer.silveran.ui.SilveranApp
import com.kyonifer.silveran.ui.SilveranViewModel
import java.io.File

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        configureSwiftNetworking(filesDir)
        enableEdgeToEdge()

        val viewModel = ViewModelProvider(
            this,
            SilveranViewModel.factory(applicationContext),
        )[SilveranViewModel::class.java]

        setContent { SilveranApp(viewModel) }
    }
}

private fun configureSwiftNetworking(filesDirectory: File) {
    val bundle = File(filesDirectory, "android-system-cacerts.pem")
    if (!bundle.exists()) {
        val certificates = File("/system/etc/security/cacerts")
            .listFiles()
            ?.sortedBy { it.name }
            .orEmpty()
        bundle.outputStream().buffered().use { output ->
            certificates.forEach { certificate ->
                certificate.inputStream().use { it.copyTo(output) }
                output.write('\n'.code)
            }
        }
    }
    // AndroidBootstrap adds another JNI runtime; CAINFO must be set before Swift loads.
    Os.setenv("URLSessionCertificateAuthorityInfoFile", bundle.absolutePath, true)
}
