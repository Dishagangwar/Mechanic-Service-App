package com.example.mechanicserviceapp.data.repository

import com.example.mechanicserviceapp.data.mapper.toMechanic
import com.example.mechanicserviceapp.domain.model.CoverageResult
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.model.MechanicCategory
import com.example.mechanicserviceapp.domain.model.SearchLocation
import com.example.mechanicserviceapp.domain.model.ServiceOption
import com.example.mechanicserviceapp.domain.repository.MechanicRepository
import com.example.mechanicserviceapp.util.Resource
import com.example.mechanicserviceapp.util.SupabaseConfig
import com.example.mechanicserviceapp.util.asRows
import com.example.mechanicserviceapp.util.bool
import com.example.mechanicserviceapp.util.int
import com.example.mechanicserviceapp.util.str
import com.example.mechanicserviceapp.util.toUserMessage
import dagger.Lazy
import io.github.jan.supabase.functions.Functions
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.postgrest.query.Order
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Reads garages out of Postgres through PostgREST.
 *
 * The list screen calls `nearby_mechanics`, a database function that does the
 * distance maths and the filtering server-side, so the phone never downloads rows
 * it is going to throw away. Coverage for an unvisited region is requested from an
 * Edge Function rather than fetched here, because the provider credentials and the
 * region cache both belong on the server.
 */
@Singleton
class MechanicRepositoryImpl @Inject constructor(
    private val postgrestProvider: Lazy<Postgrest>,
    private val functionsProvider: Lazy<Functions>
) : MechanicRepository {

    private val postgrest: Postgrest get() = postgrestProvider.get()
    private val functions: Functions get() = functionsProvider.get()

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * The last page of results. The detail screen reads from here instead of making
     * a second round trip, which also makes rotation free.
     */
    @Volatile
    private var cached: List<Mechanic> = emptyList()

    override fun getMechanics(
        location: SearchLocation,
        radiusKm: Int,
        category: MechanicCategory?,
        query: String?
    ): Flow<Resource<List<Mechanic>>> = flow {
        emit(Resource.Loading)

        if (!SupabaseConfig.isConfigured) {
            emit(Resource.Error(SupabaseConfig.SETUP_MESSAGE)); return@flow
        }
        if (!location.isValid) {
            emit(Resource.Error("Choose a location to search around.")); return@flow
        }

        try {
            val rows = postgrest.rpc(
                function = "nearby_mechanics",
                parameters = buildJsonObject {
                    put("p_lat", location.latitude)
                    put("p_lng", location.longitude)
                    put("p_radius_km", radiusKm.toDouble())
                    category?.let { put("p_category", it.wireValue) }
                    query?.takeIf { it.isNotBlank() }?.let { put("p_query", it.trim()) }
                }
            ).data

            val mechanics = json.parseToJsonElement(rows).asRows().mapNotNull { it.toMechanic() }
            cached = mechanics
            emit(Resource.Success(mechanics))
        } catch (e: Exception) {
            emit(Resource.Error(e.toUserMessage(), e))
        }
    }

    override fun getMechanicById(id: String): Flow<Resource<Mechanic>> = flow {
        emit(Resource.Loading)

        if (!SupabaseConfig.isConfigured) {
            emit(Resource.Error(SupabaseConfig.SETUP_MESSAGE)); return@flow
        }

        cached.firstOrNull { it.id == id }?.let {
            emit(Resource.Success(it)); return@flow
        }

        // Cold start straight into the detail screen (process death, deep link) leaves
        // the cache empty. Read the row directly; distance is simply unknown here,
        // since without a search location there is nothing to measure from.
        try {
            val rows = postgrest.from("mechanics_with_stats")
                .select { filter { eq("id", id) } }
                .data

            val mechanic = json.parseToJsonElement(rows).asRows()
                .firstNotNullOfOrNull { it.toMechanic() }

            if (mechanic != null) emit(Resource.Success(mechanic))
            else emit(Resource.Error("This garage is no longer listed."))
        } catch (e: Exception) {
            emit(Resource.Error(e.toUserMessage(), e))
        }
    }

    override suspend fun ensureCoverage(
        location: SearchLocation,
        radiusKm: Int
    ): Resource<CoverageResult> {
        if (!SupabaseConfig.isConfigured) return Resource.Error(SupabaseConfig.SETUP_MESSAGE)
        if (!location.isValid) return Resource.Error("Choose a location to search around.")

        return try {
            val body = functions.invoke(
                function = "nearby-import",
                body = buildJsonObject {
                    put("lat", location.latitude)
                    put("lng", location.longitude)
                    put("radius_m", radiusKm * 1000)
                }
            ).bodyAsText()

            val payload = json.parseToJsonElement(body) as? JsonObject
                ?: return Resource.Error("The coverage service returned something unexpected.")

            payload.str("error")?.let { return Resource.Error(it) }

            Resource.Success(
                CoverageResult(
                    tile = payload.str("tile").orEmpty(),
                    wasCached = payload.bool("cached") ?: false,
                    mechanicCount = payload.int("mechanic_count") ?: 0
                )
            )
        } catch (e: Exception) {
            Resource.Error(e.toUserMessage(), e)
        }
    }

    override suspend fun getServiceCatalog(): Resource<List<ServiceOption>> {
        if (!SupabaseConfig.isConfigured) return Resource.Error(SupabaseConfig.SETUP_MESSAGE)

        return try {
            val rows = postgrest.from("services")
                .select { order("sort_order", Order.ASCENDING) }
                .data

            Resource.Success(
                json.parseToJsonElement(rows).asRows().mapNotNull { row ->
                    val id = row.str("id") ?: return@mapNotNull null
                    val name = row.str("name") ?: return@mapNotNull null
                    ServiceOption(id, name)
                }
            )
        } catch (e: Exception) {
            Resource.Error(e.toUserMessage(), e)
        }
    }
}
