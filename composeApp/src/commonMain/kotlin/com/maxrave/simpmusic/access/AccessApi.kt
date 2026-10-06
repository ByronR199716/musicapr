package com.maxrave.simpmusic.access

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.content.TextContent
import io.ktor.http.isSuccess
import kotlinx.serialization.json.Json
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** Respuesta del servidor a validate_access / start_demo. */
data class ServerAccess(
    val ok: Boolean,
    val reason: String,
    val kind: String,
    val expiresMs: Long?,
    val serverMs: Long?,
    val revalidateHours: Int,
    val graceHours: Int,
)

data class PublicConfig(
    val demoEnabled: Boolean,
    val demoHours: Int,
    val donationUrl: String,
    val welcomeMessage: String,
)

/** No se pudo hablar con el servidor (sin internet, servidor pausado, error HTTP). */
class AccessUnavailableException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** Lo que AccessController necesita del servidor (permite probarlo sin red). */
interface AccessBackend {
    suspend fun validateCode(code: String, deviceId: String, deviceName: String): ServerAccess

    suspend fun startDemo(deviceId: String, deviceName: String): ServerAccess

    suspend fun publicConfig(): PublicConfig
}

class AccessApi : AccessBackend {
    private val client =
        HttpClient(CIO) {
            expectSuccess = false
            install(HttpTimeout) {
                connectTimeoutMillis = 10_000
                requestTimeoutMillis = 15_000
            }
        }

    private suspend fun rpc(function: String, body: JsonObject): JsonObject {
        val response =
            try {
                client.post("${AccessConfig.SUPABASE_URL.trimEnd('/')}/rest/v1/rpc/$function") {
                    header("apikey", AccessConfig.SUPABASE_ANON_KEY)
                    header("Authorization", "Bearer ${AccessConfig.SUPABASE_ANON_KEY}")
                    setBody(TextContent(body.toString(), ContentType.Application.Json))
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                throw AccessUnavailableException("Sin conexión", e)
            }
        val text = response.bodyAsText()
        if (!response.status.isSuccess()) {
            throw AccessUnavailableException("HTTP ${response.status.value}: ${text.take(200)}")
        }
        return try {
            Json.parseToJsonElement(text).jsonObject
        } catch (e: Exception) {
            throw AccessUnavailableException("Respuesta inválida", e)
        }
    }

    private fun JsonObject.str(key: String) = this[key]?.jsonPrimitive?.contentOrNull

    private fun JsonObject.toServerAccess() =
        ServerAccess(
            ok = this["ok"]?.jsonPrimitive?.booleanOrNull == true,
            reason = str("reason") ?: "invalid",
            kind = str("kind") ?: "code",
            expiresMs = this["expires_ms"]?.jsonPrimitive?.longOrNull,
            serverMs = this["server_ms"]?.jsonPrimitive?.longOrNull,
            revalidateHours = this["revalidate_hours"]?.jsonPrimitive?.intOrNull ?: 12,
            graceHours = this["offline_grace_hours"]?.jsonPrimitive?.intOrNull ?: 72,
        )

    override suspend fun validateCode(code: String, deviceId: String, deviceName: String): ServerAccess =
        rpc(
            "validate_access",
            buildJsonObject {
                put("p_code", code)
                put("p_device_id", deviceId)
                put("p_device_name", deviceName)
            },
        ).toServerAccess()

    override suspend fun startDemo(deviceId: String, deviceName: String): ServerAccess =
        rpc(
            "start_demo",
            buildJsonObject {
                put("p_device_id", deviceId)
                put("p_device_name", deviceName)
            },
        ).toServerAccess()

    override suspend fun publicConfig(): PublicConfig {
        val o = rpc("get_public_config", buildJsonObject { })
        return PublicConfig(
            demoEnabled = o["demo_enabled"]?.jsonPrimitive?.booleanOrNull ?: true,
            demoHours = o["demo_hours"]?.jsonPrimitive?.intOrNull ?: 6,
            donationUrl = o.str("donation_url")?.takeIf { it.isNotBlank() } ?: AccessConfig.DEFAULT_DONATION_URL,
            welcomeMessage = o.str("welcome_message").orEmpty(),
        )
    }
}
