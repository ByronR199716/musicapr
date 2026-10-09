package com.maxrave.simpmusic.access

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.koin.mp.KoinPlatform.getKoin
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

private fun appContext(): Context = getKoin().get()

// PremiumMusic tiene un solo APK (universal) para teléfono y TV box.
actual fun appUpdatePlatform(): String? = "android"

@Suppress("DEPRECATION")
private fun PackageInfo.code(): Long = if (Build.VERSION.SDK_INT >= 28) longVersionCode else versionCode.toLong()

/** Abre la conexión siguiendo redirecciones (GitHub manda a otro servidor para la descarga). */
private fun openFollowingRedirects(url: String): HttpURLConnection {
    var target = URL(url)
    repeat(6) {
        val conn = target.openConnection() as HttpURLConnection
        conn.connectTimeout = 15_000
        conn.readTimeout = 30_000
        conn.instanceFollowRedirects = false
        val code = conn.responseCode
        val location = conn.getHeaderField("Location")
        if (code in 300..399 && location != null) {
            conn.disconnect()
            target = URL(target, location)
        } else {
            return conn
        }
    }
    throw IOException("Demasiadas redirecciones")
}

actual suspend fun downloadAppUpdate(
    url: String,
    onProgress: (Float) -> Unit,
): String =
    withContext(Dispatchers.IO) {
        val context = appContext()
        val dir = File(context.cacheDir, "updates").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val file = File(dir, "update.apk")
        try {
            val conn = openFollowingRedirects(url)
            try {
                if (conn.responseCode !in 200..299) throw IOException("HTTP ${conn.responseCode}")
                val total = conn.contentLengthLong
                conn.inputStream.use { input ->
                    file.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var done = 0L
                        var lastStep = -1
                        while (true) {
                            val n = input.read(buffer)
                            if (n < 0) break
                            output.write(buffer, 0, n)
                            done += n
                            if (total > 0) {
                                val step = (done * 100 / total).toInt()
                                if (step != lastStep) {
                                    lastStep = step
                                    val fraction = done.toFloat() / total
                                    withContext(Dispatchers.Main) { onProgress(fraction) }
                                }
                            }
                        }
                    }
                }
            } finally {
                conn.disconnect()
            }
        } catch (e: IOException) {
            file.delete()
            throw Exception("No se pudo descargar. Revisa tu internet e inténtalo de nuevo.", e)
        }

        val pm = context.packageManager
        val archive = pm.getPackageArchiveInfo(file.path, 0)
        if (archive == null || archive.packageName != context.packageName) {
            file.delete()
            throw Exception("El archivo descargado no es una versión válida de la app.")
        }
        if (archive.code() <= pm.getPackageInfo(context.packageName, 0).code()) {
            file.delete()
            throw Exception("Ya tienes la versión más reciente.")
        }
        file.path
    }

actual fun canInstallAppUpdates(): Boolean = appContext().packageManager.canRequestPackageInstalls()

actual fun openInstallPermissionSettings() {
    val context = appContext()
    val intent =
        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(intent)
}

actual fun installAppUpdate(path: String) {
    val context = appContext()
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.FileProvider", File(path))
    val intent =
        Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(intent)
}
