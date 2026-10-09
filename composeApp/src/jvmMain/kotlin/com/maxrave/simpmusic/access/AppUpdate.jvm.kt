package com.maxrave.simpmusic.access

// Escritorio: sin aviso de actualización por ahora (no hay versión de PC publicada).
actual fun appUpdatePlatform(): String? = null

actual suspend fun downloadAppUpdate(
    url: String,
    onProgress: (Float) -> Unit,
): String = throw UnsupportedOperationException("No disponible en escritorio")

actual fun canInstallAppUpdates(): Boolean = false

actual fun openInstallPermissionSettings() {}

actual fun installAppUpdate(path: String) {}
