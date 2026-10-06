package com.maxrave.simpmusic.access

import com.maxrave.domain.manager.DataStoreManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.random.Random

sealed interface AccessState {
    data object Checking : AccessState

    data class Locked(
        val message: String?,
    ) : AccessState

    data class Unlocked(
        val kind: String,
        val expiresMs: Long,
        val serverOffsetMs: Long,
    ) : AccessState
}

/**
 * Decide si la app puede abrirse.
 *
 * - Con un acceso guardado y validado hace menos de `revalidate_hours`, abre sin usar internet.
 * - Si toca revalidar y no hay internet, deja usar la app hasta `offline_grace_hours`
 *   desde la última validación, siempre que el acceso no haya vencido.
 * - Si el reloj del teléfono se atrasa a propósito, exige validar en línea.
 */
class AccessController(
    private val store: DataStoreManager,
    private val api: AccessBackend = AccessApi(),
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    private val _state = MutableStateFlow<AccessState>(AccessState.Checking)
    val state: StateFlow<AccessState> = _state.asStateFlow()

    private val _config = MutableStateFlow<PublicConfig?>(null)
    val config: StateFlow<PublicConfig?> = _config.asStateFlow()

    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()

    private val mutex = Mutex()

    private data class Session(
        val kind: String,
        val code: String,
        val expiresMs: Long,
        val validatedAt: Long,
        val offsetMs: Long,
        val lastSeen: Long,
        val revalidateHours: Int,
        val graceHours: Int,
    )

    private fun now() = clock()

    private suspend fun get(key: String) = store.getString(PREFIX + key).first().orEmpty()

    private suspend fun set(
        key: String,
        value: String,
    ) = store.putString(PREFIX + key, value)

    private suspend fun deviceId(): String {
        val system = runCatching { accessDeviceId() }.getOrDefault("")
        if (system.isNotBlank()) return system
        val saved = get(K_DEVICE)
        if (saved.isNotBlank()) return saved
        val generated = "gen-" + (1..16).joinToString("") { Random.nextInt(16).toString(16) }
        set(K_DEVICE, generated)
        return generated
    }

    private fun deviceName() = runCatching { accessDeviceName() }.getOrDefault("Dispositivo").take(80)

    private suspend fun loadSession(): Session? {
        val kind = get(K_KIND)
        if (kind != "code" && kind != "demo") return null
        return Session(
            kind = kind,
            code = get(K_CODE),
            expiresMs = get(K_EXPIRES).toLongOrNull() ?: return null,
            validatedAt = get(K_VALIDATED).toLongOrNull() ?: 0L,
            offsetMs = get(K_OFFSET).toLongOrNull() ?: 0L,
            lastSeen = get(K_LAST_SEEN).toLongOrNull() ?: 0L,
            revalidateHours = get(K_REVALIDATE).toIntOrNull() ?: 12,
            graceHours = get(K_GRACE).toIntOrNull() ?: 72,
        )
    }

    private suspend fun saveSession(
        kind: String,
        code: String,
        r: ServerAccess,
    ) {
        val t = now()
        set(K_KIND, kind)
        set(K_CODE, code)
        set(K_EXPIRES, (r.expiresMs ?: t).toString())
        set(K_VALIDATED, t.toString())
        set(K_OFFSET, ((r.serverMs ?: t) - t).toString())
        set(K_LAST_SEEN, t.toString())
        set(K_REVALIDATE, r.revalidateHours.toString())
        set(K_GRACE, r.graceHours.toString())
    }

    private suspend fun clearSession() {
        listOf(K_KIND, K_CODE, K_EXPIRES, K_VALIDATED, K_OFFSET, K_LAST_SEEN).forEach { set(it, "") }
    }

    private fun unlock(s: Session) {
        _state.value = AccessState.Unlocked(s.kind, s.expiresMs, s.offsetMs)
    }

    /** Revisa el acceso guardado. Se llama al abrir la app y cada minuto mientras está abierta. */
    suspend fun check() =
        mutex.withLock {
            val s =
                loadSession() ?: run {
                    if (_state.value !is AccessState.Locked) _state.value = AccessState.Locked(null)
                    return@withLock
                }
            val t = now()
            val clockMovedBack = t + CLOCK_TOLERANCE_MS < s.lastSeen || t < s.validatedAt - CLOCK_TOLERANCE_MS
            val serverNow = t + s.offsetMs
            val expired = serverNow >= s.expiresMs
            val due = t - s.validatedAt >= s.revalidateHours * HOUR_MS

            if (!clockMovedBack && !expired && !due) {
                if (t > s.lastSeen) set(K_LAST_SEEN, t.toString())
                unlock(s)
                return@withLock
            }

            try {
                val r =
                    if (s.kind == "demo") {
                        api.startDemo(deviceId(), deviceName())
                    } else {
                        api.validateCode(s.code, deviceId(), deviceName())
                    }
                applyResult(s.kind, s.code, r)
            } catch (e: AccessUnavailableException) {
                val withinGrace = !clockMovedBack && t - s.validatedAt < s.graceHours * HOUR_MS
                when {
                    expired -> {
                        _state.value =
                            AccessState.Locked(expiredMessage(s.kind) + " Si ya te lo renovaron, conéctate a internet y vuelve a abrir la app.")
                    }

                    withinGrace -> {
                        if (t > s.lastSeen) set(K_LAST_SEEN, t.toString())
                        unlock(s)
                    }

                    else -> {
                        _state.value = AccessState.Locked("Conéctate a internet para verificar tu acceso y vuelve a abrir la app.")
                    }
                }
            }
        }

    private suspend fun applyResult(
        kind: String,
        code: String,
        r: ServerAccess,
    ) {
        if (r.ok && r.expiresMs != null) {
            saveSession(kind, code, r)
            loadSession()?.let { unlock(it) }
        } else {
            clearSession()
            _state.value = AccessState.Locked(messageFor(r.reason, kind))
        }
    }

    /** El usuario escribió un código en la pantalla de acceso. */
    suspend fun submitCode(raw: String) {
        val code = normalizeCode(raw)
        if (code.length < 6) {
            _state.value = AccessState.Locked("Escribe el código completo.")
            return
        }
        runAction { applyResult("code", code, api.validateCode(code, deviceId(), deviceName())) }
    }

    /** El usuario tocó "Probar gratis". */
    suspend fun startDemo() {
        runAction { applyResult("demo", "", api.startDemo(deviceId(), deviceName())) }
    }

    /** Sale de la sesión actual (por ejemplo, para pasar de la demo a un código). */
    suspend fun signOut() =
        mutex.withLock {
            clearSession()
            _state.value = AccessState.Locked(null)
        }

    suspend fun loadConfig() {
        try {
            _config.value = api.publicConfig()
        } catch (_: AccessUnavailableException) {
            // Se usan los valores por defecto en la pantalla.
        }
    }

    private suspend fun runAction(block: suspend () -> Unit) {
        if (_busy.value) return
        _busy.value = true
        try {
            mutex.withLock {
                try {
                    block()
                } catch (e: AccessUnavailableException) {
                    _state.value = AccessState.Locked("No se pudo conectar. Revisa tu internet e inténtalo de nuevo.")
                }
            }
        } finally {
            _busy.value = false
        }
    }

    private fun expiredMessage(kind: String) =
        if (kind == "demo") {
            "Tu demo terminó. Si te gustó la app, apoya al creador con una donación y pide tu código."
        } else {
            "Tu código venció. Pide uno nuevo para seguir escuchando."
        }

    private fun messageFor(
        reason: String,
        kind: String,
    ): String =
        when (reason) {
            "invalid" -> "Ese código no existe. Revisa que esté bien escrito."
            "disabled" -> "Este código fue desactivado. Contacta al administrador."
            "expired" -> expiredMessage(kind)
            "device_limit" -> "Este código ya se usa en el máximo de dispositivos. Pide al administrador que libere uno."
            "demo_used" -> "Ya usaste la demo en este dispositivo. Para seguir, apoya al creador con una donación y pide tu código."
            "demo_disabled" -> "La demo no está disponible por ahora."
            "bad_request" -> "No se pudo identificar este dispositivo."
            else -> "No se pudo validar el acceso."
        }

    companion object {
        private const val PREFIX = "musicapr_access_"
        private const val K_DEVICE = "device_id"
        private const val K_KIND = "kind"
        private const val K_CODE = "code"
        private const val K_EXPIRES = "expires_ms"
        private const val K_VALIDATED = "validated_ms"
        private const val K_OFFSET = "server_offset_ms"
        private const val K_LAST_SEEN = "last_seen_ms"
        private const val K_REVALIDATE = "revalidate_h"
        private const val K_GRACE = "grace_h"
        private const val HOUR_MS = 3_600_000L
        private const val CLOCK_TOLERANCE_MS = 10 * 60_000L

        fun normalizeCode(raw: String) = raw.uppercase().filter { it in 'A'..'Z' || it in '0'..'9' }.take(32)

        fun formatCode(raw: String) = normalizeCode(raw).chunked(4).joinToString("-")
    }
}
