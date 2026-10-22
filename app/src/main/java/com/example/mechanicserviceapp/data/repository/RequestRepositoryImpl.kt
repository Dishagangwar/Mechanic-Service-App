package com.example.mechanicserviceapp.data.repository

import com.example.mechanicserviceapp.data.mapper.toCustomerRequest
import com.example.mechanicserviceapp.domain.model.CustomerRequest
import com.example.mechanicserviceapp.domain.model.ServiceRequest
import com.example.mechanicserviceapp.domain.model.ServiceRequestResult
import com.example.mechanicserviceapp.domain.repository.RequestRepository
import com.example.mechanicserviceapp.util.Resource
import com.example.mechanicserviceapp.util.SupabaseConfig
import com.example.mechanicserviceapp.util.asRows
import com.example.mechanicserviceapp.util.str
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

/**
 * Bookings, stored for real.
 *
 * Note what is *not* sent on insert: no status, no ETA. Both are rejected by the
 * insert policy if supplied, because a client has no business declaring that its
 * own request is accepted or promising when the work will be done. The row starts
 * `pending` with a null ETA and only the garage can move it on.
 */
@Singleton
class RequestRepositoryImpl @Inject constructor(
    private val postgrestProvider: Lazy<Postgrest>,
    private val authProvider: Lazy<Auth>
) : RequestRepository {

    private val postgrest: Postgrest get() = postgrestProvider.get()
    private val json = Json { ignoreUnknownKeys = true }

    private fun currentUserId(): String? =
        if (SupabaseConfig.isConfigured) authProvider.get().currentUserOrNull()?.id else null

    override suspend fun submit(request: ServiceRequest): Resource<ServiceRequestResult> {
        if (!SupabaseConfig.isConfigured) return Resource.Error(SupabaseConfig.SETUP_MESSAGE)
        val userId = currentUserId()
            ?: return Resource.Error("You need to be signed in to book a service.")

        return try {
            val rows = postgrest.from("service_requests")
                .insert(
                    buildJsonObject {
                        put("customer_id", userId)
                        put("mechanic_id", request.mechanicId)
                        request.serviceId?.let { put("service_id", it) }
                        // Snapshots, so the booking stays readable later.
                        put("mechanic_name", request.mechanicName)
                        put("service_name", request.serviceName)
                        put("customer_name", request.customerName)
                        put("phone_number", request.phoneNumber)
                        put("vehicle_number", request.vehicleNumber)
                        put("problem_description", request.problemDescription)
                    }
                ) { select() }
                .data

            val row = json.parseToJsonElement(rows).asRows().firstOrNull()
                ?: return Resource.Error("The booking was not saved. Please try again.")

            Resource.Success(
                ServiceRequestResult(
                    requestId = row.str("id").orEmpty(),
                    mechanicName = row.str("mechanic_name") ?: request.mechanicName
                )
            )
        } catch (e: Exception) {
            Resource.Error(e.toUserMessage(), e)
        }
    }

    override fun myRequests(): Flow<Resource<List<CustomerRequest>>> = flow {
        emit(Resource.Loading)

        if (!SupabaseConfig.isConfigured) {
            emit(Resource.Error(SupabaseConfig.SETUP_MESSAGE)); return@flow
        }
        if (currentUserId() == null) {
            emit(Resource.Error("You need to be signed in to see your requests.")); return@flow
        }

        try {
            // The function filters on auth.uid() server-side; nothing is passed in,
            // so there is no way for a client to ask for somebody else's bookings.
            val rows = postgrest.rpc("my_requests").data
            emit(
                Resource.Success(
                    json.parseToJsonElement(rows).asRows().mapNotNull { it.toCustomerRequest() }
                )
            )
        } catch (e: Exception) {
            emit(Resource.Error(e.toUserMessage(), e))
        }
    }

    override suspend fun cancel(requestId: String): Resource<Unit> {
        if (!SupabaseConfig.isConfigured) return Resource.Error(SupabaseConfig.SETUP_MESSAGE)

        return try {
            // The transition trigger refuses this once work has started, so a stale
            // button tap fails loudly instead of appearing to work.
            postgrest.from("service_requests")
                .update({ set("status", "cancelled") }) { filter { eq("id", requestId) } }
            Resource.Success(Unit)
        } catch (e: Exception) {
            Resource.Error(e.toUserMessage(), e)
        }
    }

    override suspend fun review(
        requestId: String,
        mechanicId: String,
        rating: Int,
        comment: String?
    ): Resource<Unit> {
        if (!SupabaseConfig.isConfigured) return Resource.Error(SupabaseConfig.SETUP_MESSAGE)
        val userId = currentUserId()
            ?: return Resource.Error("You need to be signed in to leave a review.")
        if (rating !in 1..5) return Resource.Error("Pick a rating between 1 and 5 stars.")

        return try {
            postgrest.from("reviews").insert(
                buildJsonObject {
                    put("request_id", requestId)
                    put("customer_id", userId)
                    put("mechanic_id", mechanicId)
                    put("rating", rating)
                    comment?.trim()?.takeIf { it.isNotEmpty() }?.let { put("comment", it) }
                }
            )
            Resource.Success(Unit)
        } catch (e: Exception) {
            Resource.Error(e.toUserMessage(), e)
        }
    }
}
