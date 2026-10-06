package com.maxrave.simpmusic.access

// En escritorio no hay un ID del sistema: AccessController genera uno y lo guarda.
actual fun accessDeviceId(): String = ""

actual fun accessDeviceName(): String = "Escritorio (${System.getProperty("os.name") ?: "PC"})"
