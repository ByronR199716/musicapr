package com.maxrave.simpmusic.access

/**
 * Configuración del acceso por códigos.
 *
 * Copia estos valores desde Supabase > Project Settings > API.
 * La "anon public key" está pensada para ir dentro de apps: no da acceso a las tablas,
 * solo a las funciones públicas validate_access, start_demo y get_public_config.
 */
object AccessConfig {
    const val SUPABASE_URL = "https://dcgaxwkxqbyvuwgsionf.supabase.co" // ej: https://abcd1234.supabase.co
    const val SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRjZ2F4d2t4cWJ5dnV3Z3Npb25mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEyMzIxODUsImV4cCI6MjEwNjgwODE4NX0.Bql5bv4ZIPASPw558vnkTz9idcYmqqqWleMYrzcCXsc"

    /** Enlace al código fuente de esta versión (obligación de la licencia GPL-3.0). */
    const val SOURCE_CODE_URL = "https://github.com/TU_USUARIO/SimpMusic"

    /** Enlace de donación si el servidor no responde. El real se cambia desde el panel. */
    const val DEFAULT_DONATION_URL = "https://www.buymeacoffee.com/maxrave"

    const val APP_TITLE = "Musica Pr"
}
