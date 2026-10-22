package com.example.mechanicserviceapp.data.repository

import com.example.mechanicserviceapp.data.mapper.toGarageRequest
import com.example.mechanicserviceapp.data.mapper.toMechanic
import com.example.mechanicserviceapp.domain.model.GarageRequest
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.model.RequestStatus
import com.example.mechanicserviceapp.domain.repository.GarageRepository
import com.example.mechanicserviceapp.util.Diag
import com.example.mechanicserviceapp.util.Resource
import com.example.mechanicserviceapp.util.SupabaseConfig
import com.example.mechanicserviceapp.util.asRows
import com.example.mechanicserviceapp.util.toUserMessage
import dagger.Lazy
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.postgrest.Postgrest
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class GarageRepositoryImpl @Inject constructor(
    private val postgrestProvider: Lazy<Postgrest>,
    private val authProvider: Lazy<Auth>
) : GarageRepository {

    private val postgrest: Postgrest get() = postgrestProvider.get()
    private val json = Json { ignoreUnknownKeys = true }

    private fun signedIn(): Boolean =
        SupabaseConfig.isConfigured && authProvider.get().currentUserOrNull() != null

    override fun myGarages(): Flow<Resource<List<Mechanic>>> = flow {
        emit(Resource.Loading)
        if (!signedIn()) {
            emit(Resource.Error("You need to be signed in.")); return@flow
        }

        try {
            // Filters on auth.uid() server-side; nothing is passed in, so a client
            // cannot ask for somebody else's listings.
            val rows = postgrest.rpc("my_garages").data
            emit(Resource.Success(json.parseToJsonElement(rows).asRows().mapNotNull { it.toMechanic() }))
        } catch (e: Exception) {
            Diag.warn("myGarages FAILED", e)
            emit(Resource.Error(e.toUserMessage(), e))
        }
    }

    override fun incomingRequests(): Flow<Resource<List<GarageRequest>>> = flow {
        emit(Resource.Loading)
        if (!signedIn()) {
            emit(Resource.Error("You need to be signed in.")); return@flow
        }

        try {
            val rows = postgrest.rpc("my_garage_requests").data
            emit(
                Resource.Success(
                    json.parseToJsonElement(rows).asRows().mapNotNull { it.toGarageRequest() }
                )
            )
        } catch (e: Exception) {
            Diag.warn("incomingRequests FAILED", e)
            emit(Resource.Error(e.toUserMessage(), e))
        }
    }

    override suspend fun claim(mechanicId: String): Resource<Unit> = rpcUnit("claim_mechanic") {
        put("p_mechanic_id", mechanicId)
    }

    override suspend fun release(mechanicId: String): Resource<Unit> = rpcUnit("release_mechanic") {
        put("p_mechanic_id", mechanicId)
    }

    override suspend fun accept(
        requestId: String,
        etaMinutes: Int,
        note: String?
    ): Resource<Unit> {
        if (!signedIn()) return Resource.Error("You need to be signed in.")
        if (etaMinutes !in 0..10_080) return Resource.Error("Enter an ETA in minutes, up to a week.")

        return try {
            postgrest.from("service_requests").update({
                set("status", RequestStatus.ACCEPTED.wireValue)
                set("eta_minutes", etaMinutes)
                note?.trim()?.takeIf { it.isNotEmpty() }?.let { set("mechanic_note", it) }
            }) { filter { eq("id", requestId) } }
            Resource.Success(Unit)
        } catch (e: Exception) {
            Diag.warn("accept FAILED", e)
            Resource.Error(e.toUserMessage(), e)
        }
    }

    override suspend fun setStatus(requestId: String, status: RequestStatus): Resource<Unit> {
        if (!signedIn()) return Resource.Error("You need to be signed in.")

        return try {
            // The transition trigger refuses an illegal move, so a stale button
            // surfaces a real message rather than appearing to work.
            postgrest.from("service_requests").update({
                set("status", status.wireValue)
            }) { filter { eq("id", requestId) } }
            Resource.Success(Unit)
        } catch (e: Exception) {
            Diag.warn("setStatus ${status.wireValue} FAILED", e)
            Resource.Error(e.toUserMessage(), e)
        }
    }

    private suspend fun rpcUnit(
        function: String,
        parameters: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit
    ): Resource<Unit> {
        if (!signedIn()) return Resource.Error("You need to be signed in.")

        return try {
            postgrest.rpc(function, buildJsonObject(parameters))
            Resource.Success(Unit)
        } catch (e: Exception) {
            Diag.warn("$function FAILED", e)
            Resource.Error(e.toUserMessage(), e)
        }
    }
}
