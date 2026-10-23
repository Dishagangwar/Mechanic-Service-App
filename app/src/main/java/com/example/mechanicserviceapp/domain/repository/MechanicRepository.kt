package com.example.mechanicserviceapp.domain.repository

import com.example.mechanicserviceapp.domain.model.CoverageResult
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.model.MechanicCategory
import com.example.mechanicserviceapp.domain.model.SearchLocation
import com.example.mechanicserviceapp.domain.model.ServiceOption
import com.example.mechanicserviceapp.util.Resource
import kotlinx.coroutines.flow.Flow

interface MechanicRepository {

    /**
     * Garages near [location], nearest first.
     *
     * There is no parameterless overload on purpose: the app cannot list garages
     * without being told where to look, which is what keeps it from being hardwired
     * to one city.
     */
    fun getMechanics(
        location: SearchLocation,
        radiusKm: Int,
        category: MechanicCategory? = null,
        query: String? = null
    ): Flow<Resource<List<Mechanic>>>

    /**
     * One garage.
     *
     * Served from the last list result when possible, so returning from a tap
     * costs nothing. Pass [forceRefresh] after anything that changes the row
     * itself — claiming it, for instance — because that cached copy is from
     * before the change and would quietly undo it on screen.
     */
    fun getMechanicById(id: String, forceRefresh: Boolean = false): Flow<Resource<Mechanic>>

    /**
     * Asks the backend to import this region from the map provider if it has never
     * been fetched. Safe and cheap to call repeatedly — the server keeps a ledger of
     * regions it has already pulled and returns immediately for a known one.
     *
     * Returns an error only if the import itself failed; callers treat that as
     * non-fatal and keep showing whatever is already cached.
     */
    suspend fun ensureCoverage(location: SearchLocation, radiusKm: Int): Resource<CoverageResult>

    /** Every service in the catalog, for the booking form and the filter chips. */
    suspend fun getServiceCatalog(): Resource<List<ServiceOption>>
}
