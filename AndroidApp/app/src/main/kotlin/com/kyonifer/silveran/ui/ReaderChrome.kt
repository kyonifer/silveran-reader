package com.kyonifer.silveran.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.FormatAlignJustify
import androidx.compose.material.icons.automirrored.filled.FormatAlignLeft
import androidx.compose.material.icons.automirrored.filled.FormatAlignRight
import androidx.compose.material.icons.filled.FormatSize
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.automirrored.filled.RotateLeft
import androidx.compose.material.icons.automirrored.filled.RotateRight
import androidx.compose.material.icons.automirrored.filled.Toc
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.kyonifer.silveran.model.ReaderTocEntry
import kotlin.math.roundToInt
import org.json.JSONObject

// Mirrors ReaderTheme.builtInLight/builtInDark, which the Swift side applies
// as the active theme until Android grows the custom theme system.
internal fun readerChromeColors(isDark: Boolean): Pair<Color, Color> {
    return if (isDark) {
        Color(0xFF1A1A1A) to Color(0xFFEEEEEE)
    } else {
        Color.White to Color.Black
    }
}

// Defaults mirror AndroidReaderSettings, which mirrors SettingsDefaults.swift.
internal data class ReaderDisplaySettings(
    val fontSize: Double = 24.0,
    val fontFamily: String = "System Default",
    val lineSpacing: Double = 1.4,
    val marginLeftRight: Double = 2.0,
    val marginTopBottom: Double = 8.0,
    val wordSpacing: Double = 0.0,
    val letterSpacing: Double = 0.0,
    val textAlignment: String = "justify",
    val singleColumnMode: Boolean = true,
    val scrollingMode: Boolean = false,
    val enableMarginClickNavigation: Boolean = true,
) {
    fun toUpdateJson(): String = JSONObject().apply {
        put("fontSize", fontSize)
        put("fontFamily", fontFamily)
        put("lineSpacing", lineSpacing)
        put("marginLeftRight", marginLeftRight)
        put("marginTopBottom", marginTopBottom)
        put("wordSpacing", wordSpacing)
        put("letterSpacing", letterSpacing)
        put("textAlignment", textAlignment)
        put("singleColumnMode", singleColumnMode)
        put("scrollingMode", scrollingMode)
        put("enableMarginClickNavigation", enableMarginClickNavigation)
    }.toString()
}

internal fun selectedTocIndex(toc: List<ReaderTocEntry>, sectionIndex: Int?): Int? {
    if (sectionIndex == null) return null
    val exact = toc.indexOfFirst { it.sectionIndex == sectionIndex }
    if (exact >= 0) return exact
    return toc.indexOfLast { it.sectionIndex < sectionIndex }.takeIf { it >= 0 }
}

@Composable
internal fun ReaderTopBar(
    backgroundColor: Color,
    contentColor: Color,
    onBack: () -> Unit,
    onShowToc: () -> Unit,
    onShowSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(color = backgroundColor, contentColor = contentColor, modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .height(48.dp)
                .padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
            }
            Spacer(modifier = Modifier.weight(1f))
            IconButton(onClick = onShowToc) {
                Icon(Icons.AutoMirrored.Filled.Toc, contentDescription = "Contents")
            }
            IconButton(onClick = onShowSettings) {
                Icon(Icons.Filled.FormatSize, contentDescription = "Customize reader")
            }
        }
    }
}

@Composable
internal fun ReaderBottomOverlay(
    statsVisible: Boolean,
    hasAudioNarration: Boolean,
    isPlaying: Boolean,
    bookFraction: Double?,
    currentPage: Int?,
    totalPages: Int?,
    bookTimeRemaining: Double?,
    chapterTimeRemaining: Double?,
    backgroundColor: Color,
    readerControl: (String, Double, String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val statsColor = Color.Gray.copy(alpha = 0.8f)
    Surface(
        color = if (statsVisible || hasAudioNarration) backgroundColor else Color.Transparent,
        modifier = modifier,
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 20.dp, vertical = 8.dp),
        ) {
            if (statsVisible) {
                Column(
                    modifier = Modifier.align(Alignment.CenterStart),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    if (bookFraction != null) {
                        StatRow(
                            text = "${(bookFraction.coerceIn(0.0, 1.0) * 100).roundToInt()}%",
                            icon = Icons.AutoMirrored.Filled.MenuBook,
                            iconLeading = true,
                            color = statsColor,
                        )
                    }
                    if (currentPage != null && totalPages != null && totalPages > 0) {
                        StatRow(
                            text = "Page $currentPage of $totalPages",
                            icon = Icons.Filled.Bookmark,
                            iconLeading = true,
                            color = statsColor,
                        )
                    }
                }
                if (hasAudioNarration) {
                    Column(
                        modifier = Modifier.align(Alignment.CenterEnd),
                        horizontalAlignment = Alignment.End,
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        StatRow(
                            text = formatTimeHoursMinutes(bookTimeRemaining),
                            icon = Icons.AutoMirrored.Filled.MenuBook,
                            iconLeading = false,
                            color = statsColor,
                        )
                        StatRow(
                            text = formatTimeMinutesSeconds(chapterTimeRemaining),
                            icon = Icons.Filled.Bookmark,
                            iconLeading = false,
                            color = statsColor,
                        )
                    }
                }
            }
            if (hasAudioNarration) {
                Row(
                    modifier = Modifier.align(Alignment.Center),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = { readerControl("prevSentence", 0.0, "") }) {
                        Icon(
                            Icons.AutoMirrored.Filled.RotateLeft,
                            contentDescription = "Skip back",
                            tint = statsColor,
                        )
                    }
                    IconButton(onClick = { readerControl("togglePlayPause", 0.0, "") }) {
                        Icon(
                            imageVector = if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = if (isPlaying) "Pause" else "Play",
                            tint = statsColor,
                        )
                    }
                    IconButton(onClick = { readerControl("nextSentence", 0.0, "") }) {
                        Icon(
                            Icons.AutoMirrored.Filled.RotateRight,
                            contentDescription = "Skip forward",
                            tint = statsColor,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun StatRow(
    text: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    iconLeading: Boolean,
    color: Color,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (iconLeading) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.width(14.dp))
        }
        Text(text, style = MaterialTheme.typography.labelSmall, color = color)
        if (!iconLeading) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.width(14.dp))
        }
    }
}

private fun formatTimeHoursMinutes(time: Double?): String {
    if (time == null || !time.isFinite()) return "—h—m"
    val totalSeconds = time.roundToInt().coerceAtLeast(0)
    return "${totalSeconds / 3600}h${(totalSeconds % 3600) / 60}m"
}

private fun formatTimeMinutesSeconds(time: Double?): String {
    if (time == null || !time.isFinite()) return "—m—s"
    val totalSeconds = time.roundToInt().coerceAtLeast(0)
    return "${totalSeconds / 60}m${totalSeconds % 60}s"
}

@Composable
internal fun ReaderProgressHairline(
    fraction: Double,
    isDark: Boolean,
    modifier: Modifier = Modifier,
) {
    val inset = 0.1f
    Row(modifier = modifier.fillMaxWidth().height(3.dp)) {
        Spacer(modifier = Modifier.weight(inset))
        Box(modifier = Modifier.weight(1f - inset * 2)) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(fraction.coerceIn(0.0, 1.0).toFloat())
                    .height(3.dp)
                    .align(Alignment.CenterStart)
                    .background(Color.Gray.copy(alpha = if (isDark) 0.6f else 0.7f)),
            )
        }
        Spacer(modifier = Modifier.weight(inset))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ReaderTocSheet(
    toc: List<ReaderTocEntry>,
    selectedIndex: Int?,
    onSelect: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    val listState = rememberLazyListState(
        initialFirstVisibleItemIndex = (selectedIndex ?: 0).coerceAtLeast(0),
    )
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Text(
            "Contents",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
        )
        LazyColumn(state = listState, modifier = Modifier.fillMaxHeight(0.75f)) {
            itemsIndexed(toc) { index, entry ->
                val selected = index == selectedIndex
                Text(
                    entry.label,
                    style = MaterialTheme.typography.bodyLarge,
                    color = if (selected) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onSelect(index) }
                        .padding(
                            start = (24 + entry.level * 20).dp,
                            end = 24.dp,
                            top = 12.dp,
                            bottom = 12.dp,
                        ),
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ReaderSettingsSheet(
    settings: ReaderDisplaySettings,
    onChange: (ReaderDisplaySettings, Boolean) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        // Capped height so the page stays visible behind the sheet for live
        // preview, like the 0.7-fraction detent on iOS.
        Column(
            modifier = Modifier
                .fillMaxHeight(0.62f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Customize Reader", style = MaterialTheme.typography.titleMedium)
                Spacer(modifier = Modifier.weight(1f))
                TextButton(onClick = { onChange(ReaderDisplaySettings(), true) }) {
                    Text("Reset")
                }
            }

            SettingSlider(
                label = "Font Size",
                value = settings.fontSize,
                range = 8f..60f,
                format = { "${it.roundToInt()}" },
                onPreview = { onChange(settings.copy(fontSize = it.roundToInt().toDouble()), false) },
                onCommit = { onChange(settings.copy(fontSize = it.roundToInt().toDouble()), true) },
            )

            ChipRow(
                label = "Font",
                options = listOf(
                    "System Default" to "Default",
                    "serif" to "Serif",
                    "sans-serif" to "Sans",
                    "monospace" to "Mono",
                ),
                selected = settings.fontFamily,
                onSelect = { onChange(settings.copy(fontFamily = it), true) },
            )

            SettingSwitch(
                label = "Single Column",
                checked = settings.singleColumnMode || settings.scrollingMode,
                enabled = !settings.scrollingMode,
                onToggle = { onChange(settings.copy(singleColumnMode = it), true) },
            )
            SettingSwitch(
                label = "Scrolling Mode",
                checked = settings.scrollingMode,
                onToggle = { onChange(settings.copy(scrollingMode = it), true) },
            )
            SettingSwitch(
                label = "Margin Tap to Turn Pages",
                checked = settings.enableMarginClickNavigation,
                onToggle = { onChange(settings.copy(enableMarginClickNavigation = it), true) },
            )

            SettingSlider(
                label = "Line Spacing",
                value = settings.lineSpacing,
                range = 1f..2.5f,
                format = { String.format("%.1f", it) },
                onPreview = { onChange(settings.copy(lineSpacing = roundTo(it, 1)), false) },
                onCommit = { onChange(settings.copy(lineSpacing = roundTo(it, 1)), true) },
            )

            AlignmentRow(
                selected = settings.textAlignment,
                onSelect = { onChange(settings.copy(textAlignment = it), true) },
            )

            SettingSlider(
                label = "Margins (Left/Right)",
                value = settings.marginLeftRight,
                range = 0f..30f,
                format = { "${it.roundToInt()}%" },
                onPreview = {
                    onChange(settings.copy(marginLeftRight = it.roundToInt().toDouble()), false)
                },
                onCommit = {
                    onChange(settings.copy(marginLeftRight = it.roundToInt().toDouble()), true)
                },
            )
            SettingSlider(
                label = "Margins (Top/Bottom)",
                value = settings.marginTopBottom,
                range = 0f..30f,
                format = { "${it.roundToInt()}%" },
                onPreview = {
                    onChange(settings.copy(marginTopBottom = it.roundToInt().toDouble()), false)
                },
                onCommit = {
                    onChange(settings.copy(marginTopBottom = it.roundToInt().toDouble()), true)
                },
            )

            SettingSlider(
                label = "Word Spacing",
                value = settings.wordSpacing,
                range = -0.5f..2f,
                format = { String.format("%.1fem", it) },
                onPreview = { onChange(settings.copy(wordSpacing = roundTo(it, 1)), false) },
                onCommit = { onChange(settings.copy(wordSpacing = roundTo(it, 1)), true) },
            )
            SettingSlider(
                label = "Letter Spacing",
                value = settings.letterSpacing,
                range = -0.1f..0.5f,
                format = { String.format("%.2fem", it) },
                onPreview = { onChange(settings.copy(letterSpacing = roundTo(it, 2)), false) },
                onCommit = { onChange(settings.copy(letterSpacing = roundTo(it, 2)), true) },
            )
        }
    }
}

private fun roundTo(value: Float, decimals: Int): Double {
    var factor = 1.0
    repeat(decimals) { factor *= 10 }
    return (value * factor).roundToInt() / factor
}

@Composable
private fun SettingSlider(
    label: String,
    value: Double,
    range: ClosedFloatingPointRange<Float>,
    format: (Float) -> String,
    onPreview: (Float) -> Unit,
    onCommit: (Float) -> Unit,
) {
    Column {
        Text(
            "$label: ${format(value.toFloat())}",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Slider(
            value = value.toFloat(),
            onValueChange = onPreview,
            onValueChangeFinished = { onCommit(value.toFloat()) },
            valueRange = range,
        )
    }
}

@Composable
private fun SettingSwitch(
    label: String,
    checked: Boolean,
    onToggle: (Boolean) -> Unit,
    enabled: Boolean = true,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Spacer(modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onToggle, enabled = enabled)
    }
}

@Composable
private fun ChipRow(
    label: String,
    options: List<Pair<String, String>>,
    selected: String,
    onSelect: (String) -> Unit,
) {
    Column {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            options.forEach { (value, display) ->
                FilterChip(
                    selected = selected == value,
                    onClick = { onSelect(value) },
                    label = { Text(display) },
                )
            }
        }
    }
}

@Composable
private fun AlignmentRow(
    selected: String,
    onSelect: (String) -> Unit,
) {
    Column {
        Text(
            "Text Alignment",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(
                "left" to Icons.AutoMirrored.Filled.FormatAlignLeft,
                "justify" to Icons.Filled.FormatAlignJustify,
                "right" to Icons.AutoMirrored.Filled.FormatAlignRight,
            ).forEach { (value, icon) ->
                FilterChip(
                    selected = selected == value,
                    onClick = { onSelect(value) },
                    label = { Icon(icon, contentDescription = value) },
                )
            }
        }
    }
}
