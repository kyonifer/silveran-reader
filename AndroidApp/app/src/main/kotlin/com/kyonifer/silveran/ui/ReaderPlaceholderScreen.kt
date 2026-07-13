package com.kyonifer.silveran.ui

import android.text.TextUtils
import android.webkit.WebView
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.kyonifer.silveran.model.Book

@Composable
internal fun ReaderPlaceholderScreen(book: Book, mode: String, modifier: Modifier) {
    val context = LocalContext.current
    val webView = remember { WebView(context) }
    val title = TextUtils.htmlEncode(book.title)
    val authors = TextUtils.htmlEncode(book.authors)
    val modeTitle = when (mode) {
        "audio" -> "Audio player"
        "synced" -> "Readaloud reader"
        else -> "Ebook reader"
    }
    val html = remember(book.key, mode) {
        """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
              body { font: 17px sans-serif; padding: 32px; color: #222; background: #fff; }
              main { max-width: 42rem; margin: 15vh auto 0; }
              p { line-height: 1.5; color: #555; }
            </style>
          </head>
          <body><main>
            <h1>$title</h1>
            <p>$authors</p>
            <p>$modeTitle WebView placeholder. The native shell has resolved the downloaded book;
               the Foliate/player bridge can replace this page next.</p>
          </main></body>
        </html>
        """.trimIndent()
    }

    LaunchedEffect(webView, html) {
        webView.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
    }
    DisposableEffect(webView) { onDispose { webView.destroy() } }
    AndroidView(
        factory = { webView },
        modifier = modifier.fillMaxSize(),
    )
}
