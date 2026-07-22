package com.kyonifer.silveran.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.util.Log
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.RotateLeft
import androidx.compose.material.icons.filled.RotateRight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewClientCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.kyonifer.silveran.model.Book
import com.kyonifer.silveran.model.ReaderOpenResult
import com.kyonifer.silveran.model.ReaderState
import java.io.File
import org.json.JSONObject

private const val READER_ORIGIN = "https://appassets.androidplatform.net"
private const val READER_PAGE_URL = "$READER_ORIGIN/reader/foliate_wrap.html"

@Composable
internal fun ReaderScreen(
    book: Book,
    mode: String,
    openResult: ReaderOpenResult?,
    readerState: ReaderState?,
    readerControl: (String, Double, String) -> Unit,
    readerMessageFromJS: (String, String) -> Unit,
    registerWebView: (Any, WebView) -> Unit,
    unregisterWebView: (Any) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val view = LocalView.current
    val isDark = isSystemInDarkTheme()

    val webView = remember(book.id, mode) {
        createReaderWebView(context, readerMessageFromJS)
    }

    DisposableEffect(webView) {
        registerWebView(webView, webView)
        onDispose {
            unregisterWebView(webView)
            webView.destroy()
        }
    }

    LaunchedEffect(webView, openResult, isDark) {
        if (openResult != null) {
            readerControl("setDarkMode", if (isDark) 1.0 else 0.0, "")
        }
    }

    LaunchedEffect(webView, openResult?.readerPath) {
        val open = openResult ?: return@LaunchedEffect
        val bookUrl = readerContentUrl(context.filesDir, open.readerPath) ?: return@LaunchedEffect
        installReaderStartScripts(webView, bookUrl)
        webView.loadUrl(READER_PAGE_URL)
    }

    LaunchedEffect(readerState?.keepScreenOn) {
        view.keepScreenOn = readerState?.keepScreenOn == true
    }

    Box(modifier = modifier.fillMaxSize()) {
        AndroidView(factory = { webView }, modifier = Modifier.fillMaxSize())
        if (openResult == null) {
            CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
        }
        if (readerState?.hasAudioNarration == true) {
            ReadaloudControls(
                isPlaying = readerState.isPlaying,
                readerControl = readerControl,
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    }
}

@Composable
private fun ReadaloudControls(
    isPlaying: Boolean,
    readerControl: (String, Double, String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.padding(16.dp),
        shape = MaterialTheme.shapes.extraLarge,
        tonalElevation = 6.dp,
        shadowElevation = 6.dp,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = { readerControl("prevSentence", 0.0, "") }) {
                Icon(Icons.Filled.RotateLeft, contentDescription = "Skip back")
            }
            IconButton(onClick = { readerControl("togglePlayPause", 0.0, "") }) {
                Icon(
                    imageVector = if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (isPlaying) "Pause" else "Play",
                )
            }
            IconButton(onClick = { readerControl("nextSentence", 0.0, "") }) {
                Icon(Icons.Filled.RotateRight, contentDescription = "Skip forward")
            }
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
private fun createReaderWebView(
    context: Context,
    readerMessageFromJS: (String, String) -> Unit,
): WebView {
    val assetLoader = WebViewAssetLoader.Builder()
        .addPathHandler(
            "/reader/",
            MimeFixingPathHandler(WebViewAssetLoader.AssetsPathHandler(context)) { "reader/$it" },
        )
        .addPathHandler(
            "/appdata/",
            MimeFixingPathHandler(
                WebViewAssetLoader.InternalStoragePathHandler(context, context.filesDir)
            ),
        )
        .build()

    if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
        WebView.setWebContentsDebuggingEnabled(true)
    }
    return WebView(context).apply {
        // Compose's AndroidView leaves child LayoutParams at WRAP_CONTENT, and a
        // wrap-content WebView switches Chromium into grow-to-content layout
        // where percentage and vh heights resolve to 0 (blank reader).
        layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
        settings.javaScriptEnabled = true
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        setBackgroundColor(Color.TRANSPARENT)
        webViewClient = ReaderWebViewClient(assetLoader)
        addJavascriptInterface(
            object {
                @JavascriptInterface
                fun postMessage(name: String, body: String) {
                    // Swift's debugLog goes to stdout, which Android drops;
                    // mirror the JS console into logcat.
                    if (name == "ConsoleLog") Log.d("SilveranJS", body)
                    readerMessageFromJS(name, body)
                }
            },
            "SilveranNative",
        )
    }
}

private class ReaderWebViewClient(
    private val assetLoader: WebViewAssetLoader,
) : WebViewClientCompat() {
    // Fallback for WebViews without DOCUMENT_START_SCRIPT support.
    var fallbackStartScripts: List<String> = emptyList()

    override fun shouldInterceptRequest(
        view: WebView,
        request: WebResourceRequest,
    ): WebResourceResponse? = assetLoader.shouldInterceptRequest(request.url)

    override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
        super.onPageStarted(view, url, favicon)
        fallbackStartScripts.forEach { view.evaluateJavascript(it, null) }
    }
}

// The shared web stack posts through window.webkit.messageHandlers (WKWebView's
// channel); a Proxy forwards every named handler to the SilveranNative
// JavascriptInterface so the same JS runs unmodified on Android.
private const val MESSAGE_HANDLER_POLYFILL = """
    (function() {
        if (window.webkit) { return; }
        window.webkit = {
            messageHandlers: new Proxy({}, {
                get: function(target, name) {
                    return {
                        postMessage: function(body) {
                            window.SilveranNative.postMessage(
                                String(name),
                                JSON.stringify(body === undefined ? {} : body)
                            );
                        }
                    };
                }
            })
        };
    })();
"""

private const val CONSOLE_OVERRIDE = """
    (function() {
        function format(args) {
            return args.map(function(arg) {
                if (arg instanceof Error) {
                    return 'Error: ' + arg.message + '\n' + (arg.stack || '');
                }
                if (typeof arg === 'object') {
                    try { return JSON.stringify(arg); }
                    catch (e) { return String(arg); }
                }
                return String(arg);
            }).join(' ');
        }
        console.log = function() {
            window.webkit.messageHandlers.ConsoleLog.postMessage(
                {level: 'log', message: format(Array.from(arguments))});
        };
        console.warn = function() {
            window.webkit.messageHandlers.ConsoleLog.postMessage(
                {level: 'warn', message: format(Array.from(arguments))});
        };
        console.error = function() {
            window.webkit.messageHandlers.ConsoleLog.postMessage(
                {level: 'error', message: format(Array.from(arguments))});
        };
        window.addEventListener('error', function(e) {
            console.error('Global error:', e.error || e.message, 'at', e.filename, e.lineno, e.colno);
        });
        window.addEventListener('unhandledrejection', function(e) {
            console.error('Unhandled promise rejection:', e.reason);
        });
    })();
"""

private fun bookOpenScript(bookUrl: String): String {
    val urlLiteral = JSONObject.quote(bookUrl)
    return """
        (function() {
            window.silveranBookPath = $urlLiteral;
            window.nativeReady = true;
            window.jsReady = window.jsReady || false;
            window.silveranOpenedBookPath = window.silveranOpenedBookPath || null;
            window.silveranOpeningBookPath = window.silveranOpeningBookPath || null;

            window.tryOpenSilveranBook = function(reason) {
                if (!window.nativeReady || !window.jsReady || !window.silveranBookPath) {
                    return false;
                }

                const loader = window.bookLoader;
                if (!loader) {
                    window.jsReady = false;
                    return false;
                }

                if (window.silveranOpenedBookPath === window.silveranBookPath ||
                    window.silveranOpeningBookPath === window.silveranBookPath) {
                    return true;
                }

                window.silveranOpeningBookPath = window.silveranBookPath;
                console.log('[SilveranBookOpen] opening book', reason, window.silveranBookPath);

                const openPromise = loader.openBookFromDirectory(window.silveranBookPath);

                Promise.resolve(openPromise).then(function() {
                    window.silveranOpenedBookPath = window.silveranBookPath;
                    window.silveranOpeningBookPath = null;
                }).catch(function(error) {
                    window.silveranOpeningBookPath = null;
                    console.error('[SilveranBookOpen] failed to open book', error);
                });

                return true;
            };

            window.tryOpenSilveranBook('nativeReady');
        })();
    """
}

private fun installReaderStartScripts(webView: WebView, bookUrl: String) {
    val scripts = listOf(MESSAGE_HANDLER_POLYFILL, CONSOLE_OVERRIDE, bookOpenScript(bookUrl))
    if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
        scripts.forEach { script ->
            WebViewCompat.addDocumentStartJavaScript(webView, script, setOf(READER_ORIGIN))
        }
    } else {
        (webView.webViewClient as? ReaderWebViewClient)?.fallbackStartScripts = scripts
    }
}

private fun readerContentUrl(filesDir: File, readerPath: String): String? {
    val base = filesDir.canonicalFile
    val target = File(readerPath).canonicalFile
    val relative = target.relativeToOrNull(base) ?: return null
    if (relative.path.isEmpty() || relative.path.startsWith("..")) return null
    val encoded = relative.invariantSeparatorsPath
        .split("/")
        .joinToString("/") { android.net.Uri.encode(it) }
    return "$READER_ORIGIN/appdata/$encoded/"
}

private class MimeFixingPathHandler(
    private val delegate: WebViewAssetLoader.PathHandler,
    private val transform: (String) -> String = { it },
) : WebViewAssetLoader.PathHandler {
    override fun handle(path: String): WebResourceResponse? {
        val response = delegate.handle(transform(path)) ?: return null
        val mime = readerMimeType(path) ?: return response
        return WebResourceResponse(mime, null, response.data)
    }
}

// Chromium guesses MIME from the extension and misses the EPUB-specific ones;
// module scripts and XHTML refuse to load with a wrong type.
private fun readerMimeType(path: String): String? =
    when (path.substringAfterLast('.', "").lowercase()) {
        "xhtml", "xht" -> "application/xhtml+xml"
        "opf", "ncx" -> "application/xml"
        "smil" -> "application/smil+xml"
        "json" -> "application/json"
        "js", "mjs" -> "text/javascript"
        "css" -> "text/css"
        "svg" -> "image/svg+xml"
        else -> null
    }
