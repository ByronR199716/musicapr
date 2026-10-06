package com.maxrave.simpmusic.access

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.provider.Settings
import org.koin.mp.KoinPlatform.getKoin

// ANDROID_ID se mantiene al reinstalar la app (misma firma). Cambia solo al restablecer el teléfono.
@SuppressLint("HardwareIds")
actual fun accessDeviceId(): String {
    val context: Context = getKoin().get()
    val id = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
    // 9774d56d682e549c es un valor repetido en algunos equipos antiguos defectuosos
    return if (id.isNullOrBlank() || id == "9774d56d682e549c") "" else "and-$id"
}

actual fun accessDeviceName(): String {
    val maker = Build.MANUFACTURER.orEmpty().replaceFirstChar { it.uppercase() }
    val model = Build.MODEL.orEmpty()
    return if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model".trim()
}
