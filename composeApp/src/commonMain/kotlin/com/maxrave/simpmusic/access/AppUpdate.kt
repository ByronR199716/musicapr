package com.maxrave.simpmusic.access

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import com.maxrave.simpmusic.BuildKonfig
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

/*
 * Aviso de nueva versión (YTPremium/PremiumMusic, 2026-10-09).
 *
 * Al abrir la app pregunta al servidor get_app_update(servicio, plataforma). La versión se
 * publica desde el panel (pestaña Servicios > Actualizaciones). Si la instalada es menor:
 *  - menor que min_version_code → obligatoria: no se puede cerrar el aviso.
 *  - si no → opcional: "Más tarde" la oculta hasta el próximo inicio.
 * "Actualizar" descarga el APK dentro de la app y abre el instalador de Android.
 */

data class AppUpdateInfo(
    val versionCode: Int,
    val minVersionCode: Int,
    val url: String,
    val notes: String,
)

/** "android", "tv" o "pc" según la tabla app_releases; null si esta plataforma no se actualiza sola. */
expect fun appUpdatePlatform(): String?

/** Descarga el APK y devuelve la ruta local. Lanza una excepción con un mensaje para el usuario si falla. */
expect suspend fun downloadAppUpdate(
    url: String,
    onProgress: (Float) -> Unit,
): String

/** Android 8+: el usuario debe permitir "instalar apps de esta fuente" una vez. */
expect fun canInstallAppUpdates(): Boolean

expect fun openInstallPermissionSettings()

expect fun installAppUpdate(path: String)

private sealed interface UpdateUi {
    data class Available(val info: AppUpdateInfo) : UpdateUi

    data class Downloading(val info: AppUpdateInfo, val progress: Float) : UpdateUi

    data class NeedPermission(val info: AppUpdateInfo, val path: String) : UpdateUi

    data class Ready(val info: AppUpdateInfo, val path: String) : UpdateUi

    data class Failed(val info: AppUpdateInfo, val message: String) : UpdateUi
}

private val UpdateColor = Color(0xFF7C4DFF)

@Composable
fun AppUpdatePrompt() {
    val platform = remember { appUpdatePlatform() } ?: return
    val installed = BuildKonfig.versionCode
    var ui by remember { mutableStateOf<UpdateUi?>(null) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        val info =
            try {
                AccessApi().appUpdate(AccessConfig.UPDATE_SERVICE, platform)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null // sin internet: se revisa en el próximo inicio
            }
        if (info != null && info.versionCode > installed) ui = UpdateUi.Available(info)
    }

    val current = ui ?: return
    val info =
        when (current) {
            is UpdateUi.Available -> current.info
            is UpdateUi.Downloading -> current.info
            is UpdateUi.NeedPermission -> current.info
            is UpdateUi.Ready -> current.info
            is UpdateUi.Failed -> current.info
        }
    val forced = installed < info.minVersionCode

    fun install(path: String) {
        if (canInstallAppUpdates()) {
            ui = UpdateUi.Ready(info, path)
            installAppUpdate(path)
        } else {
            ui = UpdateUi.NeedPermission(info, path)
        }
    }

    fun start() {
        ui = UpdateUi.Downloading(info, 0f)
        scope.launch {
            try {
                val path = downloadAppUpdate(info.url) { p -> ui = UpdateUi.Downloading(info, p) }
                install(path)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                ui = UpdateUi.Failed(info, e.message ?: "No se pudo descargar la actualización.")
            }
        }
    }

    val busy = current is UpdateUi.Downloading
    AlertDialog(
        properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
        onDismissRequest = {},
        title = {
            Text(
                if (forced) "Actualización obligatoria" else "Nueva versión disponible",
                fontWeight = FontWeight.Bold,
            )
        },
        text = {
            Column(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
                Text(
                    if (forced) {
                        "Para seguir usando ${AccessConfig.APP_TITLE} instala la nueva versión. Tu código y tus datos se conservan."
                    } else {
                        "Hay una nueva versión de ${AccessConfig.APP_TITLE}. Tu código y tus datos se conservan."
                    },
                )
                if (info.notes.isNotBlank()) {
                    Spacer(Modifier.height(12.dp))
                    Text("Novedades", fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(4.dp))
                    Text(info.notes)
                }
                when (current) {
                    is UpdateUi.Downloading -> {
                        Spacer(Modifier.height(16.dp))
                        Text("Descargando… ${(current.progress * 100).toInt()} %")
                        Spacer(Modifier.height(8.dp))
                        LinearProgressIndicator(
                            progress = { current.progress },
                            modifier = Modifier.fillMaxWidth(),
                            color = UpdateColor,
                        )
                    }

                    is UpdateUi.NeedPermission -> {
                        Spacer(Modifier.height(16.dp))
                        Text(
                            "Falta un permiso (solo la primera vez): toca \"Dar permiso\", activa " +
                                "\"Permitir de esta fuente\", vuelve aquí y toca \"Instalar\".",
                        )
                    }

                    is UpdateUi.Ready -> {
                        Spacer(Modifier.height(16.dp))
                        Text("Toca \"Instalar\" en la ventana de Android. Si la cerraste, tócalo de nuevo aquí.")
                    }

                    is UpdateUi.Failed -> {
                        Spacer(Modifier.height(16.dp))
                        Text(current.message, color = Color(0xFFE53935))
                    }

                    is UpdateUi.Available -> {}
                }
            }
        },
        confirmButton = {
            when (current) {
                is UpdateUi.NeedPermission -> {
                    Column {
                        Button(
                            onClick = { openInstallPermissionSettings() },
                            colors = ButtonDefaults.buttonColors(containerColor = UpdateColor, contentColor = Color.White),
                        ) { Text("Dar permiso") }
                        TextButton(onClick = { install(current.path) }) { Text("Instalar") }
                    }
                }

                is UpdateUi.Ready -> {
                    Button(
                        onClick = { install(current.path) },
                        colors = ButtonDefaults.buttonColors(containerColor = UpdateColor, contentColor = Color.White),
                    ) { Text("Instalar") }
                }

                else -> {
                    Button(
                        onClick = { start() },
                        enabled = !busy,
                        colors = ButtonDefaults.buttonColors(containerColor = UpdateColor, contentColor = Color.White),
                    ) { Text(if (current is UpdateUi.Failed) "Reintentar" else "Actualizar") }
                }
            }
        },
        dismissButton = {
            if (!forced && !busy) {
                TextButton(onClick = { ui = null }) { Text("Más tarde") }
            }
        },
    )
}
