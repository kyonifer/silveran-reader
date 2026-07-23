package com.kyonifer.silveran.ui

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.util.Log
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewClientCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.kyonifer.silveran.model.Book
import com.kyonifer.silveran.model.ReaderDisplaySettings
import com.kyonifer.silveran.model.ReaderOpenResult
import com.kyonifer.silveran.model.ReaderSearchState
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
    navigateBack: () -> Unit,
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

    var displaySettings by remember(book.id, mode) { mutableStateOf(ReaderDisplaySettings()) }
    var settingsInitialized by remember(book.id, mode) { mutableStateOf(false) }
    var chromeVisible by remember(book.id, mode) { mutableStateOf(true) }
    var lastToggleCount by remember(book.id, mode) { mutableIntStateOf(0) }
    var showToc by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showManageThemes by remember { mutableStateOf(false) }
    var showSearch by remember { mutableStateOf(false) }
    var showBookmarks by remember { mutableStateOf(false) }

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

    // The Swift side loads persisted settings on open; adopt them as the
    // sheet's starting values, then treat local edits as authoritative.
    LaunchedEffect(readerState?.settings) {
        val persisted = readerState?.settings ?: return@LaunchedEffect
        if (!settingsInitialized) {
            displaySettings = persisted
            settingsInitialized = true
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

    val toggleCount = readerState?.overlayToggleCount ?: 0
    LaunchedEffect(toggleCount) {
        if (toggleCount > lastToggleCount) {
            chromeVisible = !chromeVisible
        }
        lastToggleCount = toggleCount
    }

    SystemBarsVisibility(visible = chromeVisible)

    val (fallbackBg, fallbackFg) = readerChromeColors(isDark)
    val chromeBg = parseHexColor(readerState?.backgroundColor) ?: fallbackBg
    val chromeFg = parseHexColor(readerState?.foregroundColor) ?: fallbackFg

    // WKWebView shrinks its layout viewport by the safe area, so on iOS the
    // page's top margin starts below the status bar. Android's WebView gets
    // the raw window; without this inset the toolbar lands on the first line
    // of text. Sticky maximum so hiding the bars doesn't re-paginate.
    val density = LocalDensity.current
    val statusBarTop = WindowInsets.statusBars.getTop(density)
    var webViewTopInset by remember(book.id, mode) { mutableIntStateOf(0) }
    LaunchedEffect(statusBarTop) {
        if (statusBarTop > webViewTopInset) webViewTopInset = statusBarTop
    }

    Box(modifier = modifier.fillMaxSize().background(chromeBg)) {
        AndroidView(
            factory = { webView },
            modifier = Modifier
                .fillMaxSize()
                .padding(top = with(density) { webViewTopInset.toDp() }),
        )
        if (openResult == null) {
            CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
        }

        ReaderBottomOverlay(
            statsVisible = !chromeVisible,
            hasAudioNarration = readerState?.hasAudioNarration == true,
            isPlaying = readerState?.isPlaying == true,
            bookFraction = readerState?.bookFraction,
            currentPage = readerState?.chapterCurrentPage,
            totalPages = readerState?.chapterTotalPages,
            bookTimeRemaining = readerState?.bookTimeRemaining,
            chapterTimeRemaining = readerState?.chapterTimeRemaining,
            backgroundColor = chromeBg,
            readerControl = readerControl,
            modifier = Modifier.align(Alignment.BottomCenter),
        )

        ReaderProgressHairline(
            fraction = readerState?.chapterFraction ?: 0.0,
            isDark = isDark,
            modifier = Modifier.align(Alignment.BottomCenter),
        )

        AnimatedVisibility(
            visible = chromeVisible,
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier.align(Alignment.TopCenter),
        ) {
            ReaderTopBar(
                backgroundColor = chromeBg,
                contentColor = chromeFg,
                onBack = navigateBack,
                onShowSearch = { showSearch = true },
                onShowBookmarks = { showBookmarks = true },
                onShowToc = { showToc = true },
                onShowSettings = { showSettings = true },
            )
        }
    }

    if (showBookmarks) {
        ReaderBookmarksSheet(
            highlights = readerState?.highlights.orEmpty(),
            palette = readerState?.highlightPalette.orEmpty(),
            onSelect = { highlight ->
                readerControl("goToHighlight", 0.0, highlight.id)
                showBookmarks = false
            },
            onDelete = { highlight ->
                readerControl("deleteHighlight", 0.0, highlight.id)
            },
            onDismiss = { showBookmarks = false },
        )
    }

    val highlightPalette = readerState?.highlightPalette.orEmpty()
    readerState?.pendingSelectionText?.let { selectionText ->
        HighlightEditorDialog(
            title = "Add Highlight",
            selectedText = selectionText,
            palette = highlightPalette,
            initialColorId = null,
            initialNote = "",
            isEditing = false,
            onSave = { colorId, note ->
                val payload = JSONObject().apply {
                    colorId?.let { put("colorId", it) }
                    put("note", note)
                }.toString()
                readerControl("saveHighlight", 0.0, payload)
            },
            onDelete = null,
            onDismiss = { readerControl("cancelSelection", 0.0, "") },
        )
    }

    readerState?.pendingEdit?.let { edit ->
        HighlightEditorDialog(
            title = "Edit Highlight",
            selectedText = edit.text,
            palette = highlightPalette,
            initialColorId = edit.colorId,
            initialNote = edit.note.orEmpty(),
            isEditing = true,
            onSave = { colorId, note ->
                val payload = JSONObject().apply {
                    put("id", edit.id)
                    colorId?.let { put("colorId", it) }
                    put("note", note)
                }.toString()
                readerControl("saveHighlight", 0.0, payload)
            },
            onDelete = {
                readerControl("deleteHighlight", 0.0, edit.id)
                readerControl("cancelSelection", 0.0, "")
            },
            onDismiss = { readerControl("cancelSelection", 0.0, "") },
        )
    }

    if (showSearch) {
        ReaderSearchSheet(
            search = readerState?.search ?: ReaderSearchState(),
            onSearch = { query, matchCase, matchWholeWords ->
                val request = JSONObject().apply {
                    put("query", query)
                    put("matchCase", matchCase)
                    put("matchWholeWords", matchWholeWords)
                }.toString()
                readerControl("startSearch", 0.0, request)
            },
            onClear = { readerControl("clearSearch", 0.0, "") },
            onSelect = { cfi ->
                readerControl("goToSearchResult", 0.0, cfi)
                showSearch = false
            },
            onDismiss = { showSearch = false },
        )
    }

    if (showToc) {
        ReaderTocSheet(
            toc = readerState?.toc.orEmpty(),
            selectedIndex = selectedTocIndex(
                readerState?.toc.orEmpty(),
                readerState?.selectedChapterId,
            ),
            onSelect = { index ->
                readerControl("selectTocEntry", index.toDouble(), "")
                showToc = false
            },
            onDismiss = { showToc = false },
        )
    }

    if (showSettings) {
        ReaderSettingsSheet(
            settings = displaySettings,
            themes = readerState?.themes.orEmpty(),
            selectedLightThemeId = readerState?.selectedLightThemeId,
            selectedDarkThemeId = readerState?.selectedDarkThemeId,
            hasAudioNarration = readerState?.hasAudioNarration == true,
            onChange = { updated, commit ->
                displaySettings = updated
                if (commit) {
                    readerControl("updateReaderSettings", 0.0, updated.toUpdateJson())
                }
            },
            onReset = {
                readerControl("resetReaderSettings", 0.0, "")
                settingsInitialized = false
            },
            onSelectLightTheme = { readerControl("selectLightTheme", 0.0, it) },
            onSelectDarkTheme = { readerControl("selectDarkTheme", 0.0, it) },
            onShowManageThemes = { showManageThemes = true },
            onDismiss = { showSettings = false },
        )
    }

    if (showManageThemes) {
        ManageThemesSheet(
            themes = readerState?.themes.orEmpty(),
            selectedLightThemeId = readerState?.selectedLightThemeId,
            selectedDarkThemeId = readerState?.selectedDarkThemeId,
            onSelectLightTheme = { readerControl("selectLightTheme", 0.0, it) },
            onSelectDarkTheme = { readerControl("selectDarkTheme", 0.0, it) },
            onSaveTheme = { readerControl("saveTheme", 0.0, it) },
            onDeleteTheme = { readerControl("deleteTheme", 0.0, it) },
            onResetTheme = { readerControl("resetTheme", 0.0, it) },
            onDismiss = { showManageThemes = false },
        )
    }
}

@Composable
private fun SystemBarsVisibility(visible: Boolean) {
    val view = LocalView.current
    LaunchedEffect(visible) {
        val window = view.context.findActivity()?.window ?: return@LaunchedEffect
        val controller = WindowCompat.getInsetsController(window, view)
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (visible) {
            controller.show(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.hide(WindowInsetsCompat.Type.systemBars())
        }
    }
    DisposableEffect(view) {
        onDispose {
            val window = view.context.findActivity()?.window ?: return@onDispose
            WindowCompat.getInsetsController(window, view)
                .show(WindowInsetsCompat.Type.systemBars())
        }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
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
