package com.example.mechanicserviceapp.data.remote

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.random.Random

/**
 * Serves the bundled JSON in place of a real server so the app is demoable without any
 * hosting. Installed only when [com.example.mechanicserviceapp.BuildConfig.USE_MOCK_API]
 * is true — everything above this interceptor (Retrofit, Moshi, the repository, the
 * ViewModels) runs exactly as it would against a live backend.
 */
@Singleton
class MockApiInterceptor @Inject constructor(
    @param:ApplicationContext private val context: Context
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val path = request.url.encodedPath

        // Without this the list would flash straight to content and the loading state
        // would never be visible.
        Thread.sleep(SIMULATED_LATENCY_MS)

        val json = when {
            path.endsWith(MECHANICS_PATH) -> readAsset(MECHANICS_ASSET)
            path.endsWith(SERVICE_REQUEST_PATH) -> confirmationJson()
            else -> return chain.proceed(request)
        }

        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(json.toResponseBody(JSON_MEDIA_TYPE))
            .build()
    }

    private fun readAsset(name: String): String = try {
        context.assets.open(name).bufferedReader().use { it.readText() }
    } catch (e: IOException) {
        throw IOException("Could not read bundled asset '$name'", e)
    }

    private fun confirmationJson(): String {
        val requestId = "REQ-${Random.nextInt(100_000, 999_999)}"
        val eta = Random.nextInt(20, 60)
        return """
            {
              "request_id": "$requestId",
              "message": "Your service request has been confirmed. The garage will call you shortly.",
              "eta_minutes": $eta
            }
        """.trimIndent()
    }

    private companion object {
        const val SIMULATED_LATENCY_MS = 700L
        const val MECHANICS_PATH = "mechanics.json"
        const val SERVICE_REQUEST_PATH = "service-requests"
        const val MECHANICS_ASSET = "mechanics.json"
        val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
    }
}
