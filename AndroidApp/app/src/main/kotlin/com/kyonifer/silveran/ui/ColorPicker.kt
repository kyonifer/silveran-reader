package com.kyonifer.silveran.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import kotlin.math.roundToInt

internal fun colorToHex(color: Color): String =
    String.format("#%06X", color.toArgb() and 0xFFFFFF)

@Composable
internal fun ColorPickerDialog(
    title: String,
    initialColor: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val initial = remember { parseHexColor(initialColor) ?: Color.White }
    val initialHsv = remember {
        FloatArray(3).also { android.graphics.Color.colorToHSV(initial.toArgb(), it) }
    }
    var hue by remember { mutableFloatStateOf(initialHsv[0]) }
    var saturation by remember { mutableFloatStateOf(initialHsv[1]) }
    var brightness by remember { mutableFloatStateOf(initialHsv[2]) }
    var hexText by remember { mutableStateOf(colorToHex(initial)) }

    val current = Color.hsv(hue.coerceIn(0f, 360f), saturation, brightness)

    fun adoptColor(color: Color) {
        val hsv = FloatArray(3)
        android.graphics.Color.colorToHSV(color.toArgb(), hsv)
        hue = hsv[0]
        saturation = hsv[1]
        brightness = hsv[2]
        hexText = colorToHex(color)
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(shape = RoundedCornerShape(24.dp), tonalElevation = 6.dp) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        title,
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.weight(1f),
                    )
                    ColorChip(initial)
                    Text(
                        "→",
                        modifier = Modifier.padding(horizontal = 6.dp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    ColorChip(current)
                }
                SaturationBrightnessPanel(
                    hue = hue,
                    saturation = saturation,
                    brightness = brightness,
                    onChange = { s, b ->
                        saturation = s
                        brightness = b
                        hexText = colorToHex(Color.hsv(hue.coerceIn(0f, 360f), s, b))
                    },
                )
                HueSlider(
                    hue = hue,
                    onChange = {
                        hue = it
                        hexText = colorToHex(
                            Color.hsv(it.coerceIn(0f, 360f), saturation, brightness)
                        )
                    },
                )
                OutlinedTextField(
                    value = hexText,
                    onValueChange = { typed ->
                        hexText = typed
                        parseHexColor(typed.trim())?.let { color ->
                            val hsv = FloatArray(3)
                            android.graphics.Color.colorToHSV(color.toArgb(), hsv)
                            hue = hsv[0]
                            saturation = hsv[1]
                            brightness = hsv[2]
                        }
                    },
                    label = { Text("Hex") },
                    singleLine = true,
                    isError = parseHexColor(hexText.trim()) == null,
                    modifier = Modifier.fillMaxWidth(),
                )
                themePresetColors.chunked(7).forEach { rowColors ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        rowColors.forEach { preset ->
                            val presetColor = parseHexColor(preset) ?: Color.Transparent
                            val selected = colorToHex(current).equals(preset, ignoreCase = true)
                            Box(
                                modifier = Modifier
                                    .size(30.dp)
                                    .background(presetColor, CircleShape)
                                    .border(
                                        width = if (selected) 2.dp else 1.dp,
                                        color = if (selected) {
                                            MaterialTheme.colorScheme.primary
                                        } else {
                                            Color.Gray.copy(alpha = 0.5f)
                                        },
                                        shape = CircleShape,
                                    )
                                    .clickable { adoptColor(presetColor) },
                            )
                        }
                    }
                }
                Row(modifier = Modifier.fillMaxWidth()) {
                    Spacer(modifier = Modifier.weight(1f))
                    TextButton(onClick = onDismiss) { Text("Cancel") }
                    TextButton(onClick = { onConfirm(colorToHex(current)) }) { Text("Done") }
                }
            }
        }
    }
}

@Composable
private fun ColorChip(color: Color) {
    Box(
        modifier = Modifier
            .size(30.dp)
            .background(color, CircleShape)
            .border(1.dp, Color.Gray.copy(alpha = 0.5f), CircleShape),
    )
}

@Composable
private fun SaturationBrightnessPanel(
    hue: Float,
    saturation: Float,
    brightness: Float,
    onChange: (Float, Float) -> Unit,
) {
    var panelSize by remember { mutableStateOf(IntSize.Zero) }
    fun report(position: Offset) {
        if (panelSize.width <= 0 || panelSize.height <= 0) return
        onChange(
            (position.x / panelSize.width).coerceIn(0f, 1f),
            1f - (position.y / panelSize.height).coerceIn(0f, 1f),
        )
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(190.dp)
            .onSizeChanged { panelSize = it }
            .clip(RoundedCornerShape(14.dp))
            .background(
                Brush.horizontalGradient(
                    listOf(Color.White, Color.hsv(hue.coerceIn(0f, 360f), 1f, 1f))
                )
            )
            .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black)))
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { report(it) },
                    onDrag = { change, _ ->
                        change.consume()
                        report(change.position)
                    },
                )
            }
            .pointerInput(Unit) { detectTapGestures { report(it) } },
    ) {
        PickerThumb(
            color = Color.hsv(hue.coerceIn(0f, 360f), saturation, brightness),
            position = IntOffset(
                (saturation * panelSize.width).roundToInt(),
                ((1f - brightness) * panelSize.height).roundToInt(),
            ),
        )
    }
}

@Composable
private fun HueSlider(hue: Float, onChange: (Float) -> Unit) {
    var sliderSize by remember { mutableStateOf(IntSize.Zero) }
    val hueColors = remember { (0..360 step 60).map { Color.hsv(it.toFloat(), 1f, 1f) } }
    fun report(position: Offset) {
        if (sliderSize.width <= 0) return
        onChange((position.x / sliderSize.width).coerceIn(0f, 1f) * 360f)
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(28.dp)
            .onSizeChanged { sliderSize = it }
            .clip(RoundedCornerShape(14.dp))
            .background(Brush.horizontalGradient(hueColors))
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { report(it) },
                    onDrag = { change, _ ->
                        change.consume()
                        report(change.position)
                    },
                )
            }
            .pointerInput(Unit) { detectTapGestures { report(it) } },
    ) {
        PickerThumb(
            color = Color.hsv(hue.coerceIn(0f, 360f), 1f, 1f),
            position = IntOffset(
                (hue / 360f * sliderSize.width).roundToInt(),
                sliderSize.height / 2,
            ),
        )
    }
}

@Composable
private fun PickerThumb(color: Color, position: IntOffset) {
    val radius = with(androidx.compose.ui.platform.LocalDensity.current) { 11.dp.roundToPx() }
    Box(
        modifier = Modifier
            .offset { IntOffset(position.x - radius, position.y - radius) }
            .size(22.dp)
            .shadow(2.dp, CircleShape)
            .background(color, CircleShape)
            .border(3.dp, Color.White, CircleShape),
    )
}
