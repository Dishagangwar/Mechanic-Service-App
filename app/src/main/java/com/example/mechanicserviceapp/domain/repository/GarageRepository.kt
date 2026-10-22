package com.example.mechanicserviceapp.domain.repository

import com.example.mechanicserviceapp.domain.model.GarageRequest
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.model.RequestStatus
import com.example.mechanicserviceapp.util.Resource
import kotlinx.coroutines.flow.Flow

/**
 * The garage owner's side of the app.
 *
 * Without this the whole loop was half-built: a customer could file a request
 * and then nothing could ever move it on, so every booking sat at `pending`
 * forever unless somebody edited the database by hand.
 */
interface GarageRepository {

    /** Listings this user has claimed. */
    fun myGarages(): Flow<Resource<List<Mechanic>>>

    /** Bookings against any garage this user owns, undecided ones first. */
    fun incomingRequests(): Flow<Resource<List<GarageRequest>>>

    /**
     * Take ownership of an unclaimed listing. Fails if somebody else already
     * holds it — the database decides, not the client.
     */
    suspend fun claim(mechanicId: String): Resource<Unit>

    suspend fun release(mechanicId: String): Resource<Unit>

    /**
     * Say yes, and commit to a time. This is the only place an ETA can come
     * from: the customer's app never invents one.
     */
    suspend fun accept(requestId: String, etaMinutes: Int, note: String?): Resource<Unit>

    /**
     * Move a booking along. The database's transition trigger rejects anything
     * out of order, so a stale button fails loudly rather than silently.
     */
    suspend fun setStatus(requestId: String, status: RequestStatus): Resource<Unit>
}
