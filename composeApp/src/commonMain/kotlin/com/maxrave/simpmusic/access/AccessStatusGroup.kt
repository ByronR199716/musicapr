package com.maxrave.simpmusic.access

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.maxrave.simpmusic.ui.component.SettingGroup
import com.maxrave.simpmusic.ui.component.SettingItem
import kotlinx.coroutines.delay
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** "Mi acceso" en Ajustes: tipo de acceso, tiempo restante y fecha de vencimiento. */
@Composable
fun AccessStatusGroup() {
    val status = LocalAccessStatus.current ?: return
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            nowMs = System.currentTimeMillis()
            delay(30_000)
        }
    }
    val leftMs = status.expiresMs - (nowMs + status.serverOffsetMs)
    val isDemo = status.kind == "demo"
    val expiresText =
        DateTimeFormatter
            .ofPattern("d 'de' MMMM 'de' yyyy, HH:mm", Locale.forLanguageTag("es"))
            .format(Instant.ofEpochMilli(status.expiresMs - status.serverOffsetMs).atZone(ZoneId.systemDefault()))

    SettingGroup(title = "Mi acceso") {
        SettingItem(
            title = "Tiempo restante",
            subtitle = formatRemaining(leftMs),
        )
        SettingItem(
            title = "Vence",
            subtitle = expiresText,
        )
        SettingItem(
            title = "Tipo de acceso",
            subtitle =
                if (isDemo || status.code.isBlank()) {
                    "Demo de prueba"
                } else {
                    "Código ${AccessController.formatCode(status.code)}"
                },
        )
    }
}

private fun formatRemaining(ms: Long): String {
    if (ms <= 0) return "Vencido"
    val totalMinutes = ms / 60_000
    val days = totalMinutes / (60 * 24)
    val hours = (totalMinutes / 60) % 24
    val minutes = totalMinutes % 60
    return when {
        days >= 1 -> "${plural(days, "día", "días")} y ${plural(hours, "hora", "horas")}"
        hours >= 1 -> "${plural(hours, "hora", "horas")} y ${plural(minutes, "minuto", "minutos")}"
        else -> plural(minutes.coerceAtLeast(1), "minuto", "minutos")
    }
}

private fun plural(
    n: Long,
    one: String,
    many: String,
) = "$n ${if (n == 1L) one else many}"
