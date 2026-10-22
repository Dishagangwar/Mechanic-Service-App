package com.example.mechanicserviceapp.domain.repository

import com.example.mechanicserviceapp.domain.model.CustomerRequest
import com.example.mechanicserviceapp.domain.model.ServiceRequest
import com.example.mechanicserviceapp.domain.model.ServiceRequestResult
import com.example.mechanicserviceapp.util.Resource
import kotlinx.coroutines.flow.Flow

/**
 * Bookings. Split out of [MechanicRepository] because a booking now has a life of
 * its own — it is stored, it has a status somebody else changes, and it can be
 * reviewed afterwards.
 */
interface RequestRepository {

    suspend fun submit(request: ServiceRequest): Resource<ServiceRequestResult>

    /** The signed-in user's bookings, newest first. */
    fun myRequests(): Flow<Resource<List<CustomerRequest>>>

    /**
     * Withdraw a booking. The database only permits this while it is still pending
     * or accepted, so a late call fails rather than silently doing nothing.
     */
    suspend fun cancel(requestId: String): Resource<Unit>

    /**
     * Rate a completed booking. Row level security requires the booking to be yours
     * and to be completed, so an unearned review is rejected by the server.
     */
    suspend fun review(
        requestId: String,
        mechanicId: String,
        rating: Int,
        comment: String?
    ): Resource<Unit>
}
