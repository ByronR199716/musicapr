package com.maxrave.simpmusic.access

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.maxrave.domain.manager.DataStoreManager
import com.maxrave.simpmusic.expect.openUrl
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.jetbrains.compose.resources.painterResource
import org.koin.compose.koinInject
import simpmusic.composeapp.generated.resources.Res
import simpmusic.composeapp.generated.resources.app_icon

private val RedeemColor = Color(0xFF7C4DFF)

/** El acceso activo (código o demo), para mostrar el tiempo restante dentro de la app. */
val LocalAccessStatus = compositionLocalOf<AccessState.Unlocked?> { null }

/**
 * Envuelve la app: muestra la pantalla de acceso hasta que haya un código o una demo válidos.
 * [onLocked] se llama cuando el acceso termina con la app abierta (por ejemplo, para detener la música).
 */
@Composable
fun AccessGate(
    onLocked: () -> Unit,
    content: @Composable () -> Unit,
) {
    val store: DataStoreManager = koinInject()
    val controller = remember { AccessRuntime.controller(store) }
    val state by controller.state.collectAsState()
    var wasUnlocked by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { controller.check() }

    // Mientras la app está abierta, revisa cada minuto (sin internet salvo que toque revalidar).
    LaunchedEffect(state is AccessState.Unlocked) {
        while (state is AccessState.Unlocked) {
            delay(60_000)
            controller.check()
        }
    }

    LaunchedEffect(state) {
        when (state) {
            is AccessState.Unlocked -> {
                wasUnlocked = true
            }

            is AccessState.Locked -> {
                if (wasUnlocked) {
                    wasUnlocked = false
                    onLocked()
                }
            }

            AccessState.Checking -> {}
        }
    }

    when (val s = state) {
        AccessState.Checking -> {
            Box(
                Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background),
                contentAlignment = Alignment.Center,
            ) { CircularProgressIndicator() }
        }

        is AccessState.Locked -> {
            AccessScreen(controller, s.message)
        }

        is AccessState.Unlocked -> {
            CompositionLocalProvider(LocalAccessStatus provides s) {
                Box(Modifier.fillMaxSize()) {
                    content()
                    if (s.kind == "demo") DemoBadge(controller, s)
                }
            }
        }
    }
}

@Composable
private fun AccessScreen(
    controller: AccessController,
    message: String?,
) {
    val scope = rememberCoroutineScope()
    val config by controller.config.collectAsState()
    val busy by controller.busy.collectAsState()
    var field by remember { mutableStateOf(TextFieldValue("")) }
    val canSubmit = !busy && AccessController.normalizeCode(field.text).length >= 6
    val submit: () -> Unit = { if (canSubmit) scope.launch { controller.submitCode(field.text) } }

    LaunchedEffect(Unit) { controller.loadConfig() }

    Column(
        modifier =
            Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
                .safeDrawingPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 32.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Image(
            painter = painterResource(Res.drawable.app_icon),
            contentDescription = null,
            modifier = Modifier.size(84.dp).clip(CircleShape),
        )
        Text(
            text = AccessConfig.APP_TITLE,
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onBackground,
        )
        Text(
            text = "Ingresa tu código de acceso",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onBackground,
        )
        config?.welcomeMessage?.takeIf { it.isNotBlank() }?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = 420.dp),
            )
        }
        Spacer(Modifier.height(4.dp))
        OutlinedTextField(
            value = field,
            onValueChange = {
                val formatted = AccessController.formatCode(it.text)
                field = TextFieldValue(formatted, TextRange(formatted.length))
            },
            singleLine = true,
            label = { Text("Código") },
            placeholder = { Text("XXXX-XXXX-XXXX", fontFamily = FontFamily.Monospace) },
            textStyle = MaterialTheme.typography.titleMedium.copy(fontFamily = FontFamily.Monospace, letterSpacing = 2.sp),
            keyboardOptions =
                KeyboardOptions(
                    capitalization = KeyboardCapitalization.Characters,
                    autoCorrectEnabled = false,
                    imeAction = ImeAction.Done,
                ),
            keyboardActions = KeyboardActions(onDone = { submit() }),
            modifier = Modifier.widthIn(max = 420.dp).fillMaxWidth(),
        )
        message?.let {
            Text(
                text = it,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = 420.dp),
            )
        }
        Button(
            onClick = submit,
            enabled = canSubmit,
            colors =
                ButtonDefaults.buttonColors(
                    containerColor = RedeemColor,
                    contentColor = Color.White,
                    disabledContainerColor = RedeemColor.copy(alpha = 0.35f),
                    disabledContentColor = Color.White.copy(alpha = 0.7f),
                ),
            modifier = Modifier.widthIn(max = 420.dp).fillMaxWidth().height(52.dp),
        ) {
            if (busy) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Color.White)
            } else {
                // typo() lleva su propio color; el texto toma el del botón.
                Text("Canjear código", color = LocalContentColor.current, fontWeight = FontWeight.Bold)
            }
        }
        // Aviso oculto en la app (se deja como referencia). La atribución a SimpMusic y su
        // licencia GPL-3.0 siguen en Ajustes > Versión (créditos) y en el repositorio público.
        // Spacer(Modifier.height(8.dp))
        // Text(
        //     text = "Versión no oficial basada en SimpMusic, de maxrave-dev (licencia GPL-3.0). Toca aquí para ver el código fuente.",
        //     style = MaterialTheme.typography.bodySmall,
        //     color = MaterialTheme.colorScheme.onSurfaceVariant,
        //     textAlign = TextAlign.Center,
        //     modifier =
        //         Modifier
        //             .widthIn(max = 420.dp)
        //             .clip(RoundedCornerShape(8.dp))
        //             .clickable { openUrl(AccessConfig.SOURCE_CODE_URL) }
        //             .padding(8.dp),
        // )
    }
}

/** Indicador pequeño durante la demo, con opción de pasar a un código. */
@Composable
private fun DemoBadge(
    controller: AccessController,
    s: AccessState.Unlocked,
) {
    val scope = rememberCoroutineScope()
    var showDialog by remember { mutableStateOf(false) }
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            nowMs = System.currentTimeMillis()
            delay(30_000)
        }
    }
    val leftMin = ((s.expiresMs - (nowMs + s.serverOffsetMs)) / 60_000).coerceAtLeast(0)
    val leftText = if (leftMin >= 60) "${leftMin / 60} h ${leftMin % 60} min" else "$leftMin min"

    Box(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
        Surface(
            onClick = { showDialog = true },
            shape = RoundedCornerShape(50),
            color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.92f),
            contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
            modifier = Modifier.padding(top = 4.dp),
        ) {
            Text(
                text = "Demo · quedan $leftText · Tengo un código",
                style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 5.dp),
            )
        }
    }
    if (showDialog) {
        AlertDialog(
            onDismissRequest = { showDialog = false },
            title = { Text("¿Ya tienes un código?") },
            text = { Text("Saldrás de la demo para escribir tu código de regalo.") },
            confirmButton = {
                TextButton(onClick = {
                    showDialog = false
                    scope.launch { controller.signOut() }
                }) { Text("Ingresar código", color = LocalContentColor.current) }
            },
            dismissButton = { TextButton(onClick = { showDialog = false }) { Text("Seguir en la demo", color = LocalContentColor.current) } },
        )
    }
}
