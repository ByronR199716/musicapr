package com.maxrave.simpmusic.access

import com.maxrave.domain.manager.DataStoreManager
import com.maxrave.domain.mediaservice.handler.MediaPlayerHandler
import com.maxrave.domain.mediaservice.handler.PlayerEvent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Un solo [AccessController] para toda la app: lo usan la pantalla de acceso y [AccessPlaybackGuard],
 * así los dos ven el mismo estado (si uno bloquea, el otro se entera).
 */
object AccessRuntime {
    @Volatile
    private var instance: AccessController? = null

    fun controller(store: DataStoreManager): AccessController =
        instance ?: synchronized(this) {
            instance ?: AccessController(store).also { instance = it }
        }
}

/**
 * Detiene la música cuando el acceso termina, aunque la app esté cerrada.
 *
 * La pantalla de acceso solo vigila mientras se ve. La música la reproduce el servicio de
 * reproducción (la notificación), que sigue vivo con la app cerrada. Este guardia vive con el
 * proceso (se arranca en la Application) y:
 * - revisa el acceso cada vez que empieza a sonar algo (play desde la notificación, audífonos, etc.);
 * - mientras suena, revisa cada minuto.
 * Si el acceso venció o fue desactivado, para la música, vacía la cola y quita la notificación.
 * Sin internet se respetan las mismas reglas de siempre (horas de gracia).
 */
object AccessPlaybackGuard {
    private const val CHECK_EVERY_MS = 60_000L

    private var started = false

    fun start(
        handler: MediaPlayerHandler,
        store: DataStoreManager,
    ) {
        if (started) return
        started = true
        val controller = AccessRuntime.controller(store)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

        suspend fun checkAndStopIfLocked() {
            runCatching { controller.check() }
            val hasMusic = handler.controlState.value.isPlaying || handler.nowPlaying.value != null
            if (controller.state.value is AccessState.Locked && hasMusic) {
                withContext(Dispatchers.Main) {
                    runCatching {
                        handler.resetSongAndQueue()
                        handler.onPlayerEvent(PlayerEvent.Stop)
                    }
                }
            }
        }

        // Al empezar a sonar.
        scope.launch {
            handler.controlState
                .map { it.isPlaying }
                .distinctUntilChanged()
                .filter { it }
                .collect { checkAndStopIfLocked() }
        }

        // Mientras suena.
        scope.launch {
            while (true) {
                delay(CHECK_EVERY_MS)
                if (handler.controlState.value.isPlaying) checkAndStopIfLocked()
            }
        }
    }
}
