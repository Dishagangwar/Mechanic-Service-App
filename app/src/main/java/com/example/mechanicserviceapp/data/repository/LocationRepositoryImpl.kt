package com.example.mechanicserviceapp.data.repository

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.os.Build
import androidx.core.content.ContextCompat
import com.example.mechanicserviceapp.domain.model.SearchLocation
import com.example.mechanicserviceapp.domain.repository.LocationRepository
import com.example.mechanicserviceapp.util.Resource
import com.example.mechanicserviceapp.util.SupabaseConfig
import com.example.mechanicserviceapp.util.asRows
import com.example.mechanicserviceapp.util.double
import com.example.mechanicserviceapp.util.str
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.Task
import dagger.Lazy
import dagger.hilt.android.qualifiers.ApplicationContext
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.postgrest.Postgrest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.IOException
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Where the user is, or where they said to look.
 *
 * Place-name lookup uses Android's own [Geocoder] rather than a paid places API:
 * resolving "Kolhapur" or a pincode to a coordinate needs no billing account and no
 * key in the APK. Only coarse location is requested — a 5-25 km radius search does
 * not need street-level precision, and asking for less is easier to grant.
 */
@Singleton
class LocationRepositoryImpl @Inject constructor(
    @param:ApplicationContext private val context: Context,
    private val postgrestProvider: Lazy<Postgrest>,
    private val authProvider: Lazy<Auth>
) : LocationRepository {

    private val json = Json { ignoreUnknownKeys = true }

    private val fusedClient by lazy {
        LocationServices.getFusedLocationProviderClient(context)
    }

    override fun hasLocationPermission(): Boolean =
        PERMISSIONS.any {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }

    override suspend fun currentLocation(): Resource<SearchLocation> {
        if (!hasLocationPermission()) {
            return Resource.Error("Location permission is needed to find garages near you.")
        }

        return try {
            // lastLocation is effectively free when something else has recently asked
            // for a fix; only pay for a fresh one when there is nothing cached.
            val location = fusedClient.lastLocation.awaitOrNull()
                ?: fusedClient.getCurrentLocation(
                    CurrentLocationRequest.Builder()
                        .setPriority(Priority.PRIORITY_BALANCED_POWER_ACCURACY)
                        .setDurationMillis(FIX_TIMEOUT_MS)
                        .build(),
                    null
                ).awaitOrNull()
                ?: return Resource.Error(
                    "Couldn't get a location fix. Try again outdoors, or search for your area."
                )

            Resource.Success(
                SearchLocation(
                    latitude = location.latitude,
                    longitude = location.longitude,
                    label = describe(location) ?: "Current location",
                    origin = SearchLocation.Origin.DEVICE
                )
            )
        } catch (e: SecurityException) {
            Resource.Error("Location permission is needed to find garages near you.")
        } catch (e: Exception) {
            Resource.Error("Couldn't determine your location. Try searching for your area.", e)
        }
    }

    override suspend fun search(query: String): Resource<List<SearchLocation>> {
        val text = query.trim()
        if (text.length < 3) return Resource.Error("Type at least three characters.")
        if (!Geocoder.isPresent()) {
            return Resource.Error("Place search isn't available on this device.")
        }

        return try {
            val addresses = geocode(text)
            if (addresses.isEmpty()) {
                Resource.Error("No place matched \"$text\". Try a city or area name.")
            } else {
                Resource.Success(
                    addresses.mapNotNull { it.toSearchLocation() }.distinctBy { it.label }
                )
            }
        } catch (e: IOException) {
            Resource.Error("Place search needs a network connection.", e)
        } catch (e: Exception) {
            Resource.Error("Couldn't search for that place. Try again.", e)
        }
    }

    override suspend fun lastUsedLocation(): SearchLocation? {
        if (!SupabaseConfig.isConfigured) return null
        val user = authProvider.get().currentUserOrNull() ?: return null

        return try {
            val rows = postgrestProvider.get().from("profiles")
                .select { filter { eq("id", user.id) } }
                .data
            val row = json.parseToJsonElement(rows).asRows().firstOrNull() ?: return null
            val lat = row.double("last_lat") ?: return null
            val lng = row.double("last_lng") ?: return null

            SearchLocation(
                latitude = lat,
                longitude = lng,
                label = row.str("last_label") ?: "Last used location",
                origin = SearchLocation.Origin.SAVED
            ).takeIf { it.isValid }
        } catch (e: Exception) {
            // A missing saved location is not worth surfacing; the picker opens instead.
            null
        }
    }

    override suspend fun rememberLocation(location: SearchLocation) {
        if (!SupabaseConfig.isConfigured || !location.isValid) return
        val user = authProvider.get().currentUserOrNull() ?: return

        runCatching {
            postgrestProvider.get().from("profiles").update(
                buildJsonObject {
                    put("last_lat", location.latitude)
                    put("last_lng", location.longitude)
                    put("last_label", location.label)
                }
            ) { filter { eq("id", user.id) } }
        }
        // Deliberately silent: failing to remember a location must not interrupt a
        // search the user already asked for.
    }

    // ------------------------------------------------------------------ geocoding

    private suspend fun geocode(text: String): List<Address> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            suspendCancellableCoroutine { cont ->
                Geocoder(context, Locale.getDefault())
                    .getFromLocationName(text, MAX_RESULTS, object : Geocoder.GeocodeListener {
                        override fun onGeocode(results: MutableList<Address>) {
                            if (cont.isActive) cont.resume(results)
                        }

                        override fun onError(errorMessage: String?) {
                            if (cont.isActive) cont.resume(emptyList())
                        }
                    })
            }
        } else {
            // The blocking overload is deprecated from API 33 but is the only option
            // below it, and it does network I/O.
            withContext(Dispatchers.IO) {
                @Suppress("DEPRECATION")
                Geocoder(context, Locale.getDefault())
                    .getFromLocationName(text, MAX_RESULTS)
                    .orEmpty()
            }
        }

    private suspend fun describe(location: Location): String? =
        runCatching {
            val addresses = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                suspendCancellableCoroutine { cont ->
                    Geocoder(context, Locale.getDefault()).getFromLocation(
                        location.latitude, location.longitude, 1,
                        object : Geocoder.GeocodeListener {
                            override fun onGeocode(results: MutableList<Address>) {
                                if (cont.isActive) cont.resume(results)
                            }

                            override fun onError(errorMessage: String?) {
                                if (cont.isActive) cont.resume(emptyList())
                            }
                        }
                    )
                }
            } else {
                withContext(Dispatchers.IO) {
                    @Suppress("DEPRECATION")
                    Geocoder(context, Locale.getDefault())
                        .getFromLocation(location.latitude, location.longitude, 1)
                        .orEmpty()
                }
            }
            addresses.firstOrNull()?.shortLabel()
        }.getOrNull()

    private fun Address.toSearchLocation(): SearchLocation? {
        if (latitude == 0.0 && longitude == 0.0) return null
        return SearchLocation(
            latitude = latitude,
            longitude = longitude,
            label = shortLabel() ?: return null,
            origin = SearchLocation.Origin.SEARCHED
        )
    }

    /** "Kothrud, Pune" rather than the full postal address. */
    private fun Address.shortLabel(): String? {
        val parts = listOfNotNull(
            subLocality ?: locality ?: subAdminArea,
            adminArea?.takeIf { it != (subLocality ?: locality ?: subAdminArea) }
        ).distinct().filter { it.isNotBlank() }

        return parts.joinToString(", ").ifBlank {
            featureName?.takeIf { it.isNotBlank() } ?: countryName
        }
    }

    // -------------------------------------------------------------- task bridging

    /**
     * Bridges a Play Services [Task] into a coroutine. Hand-rolled rather than
     * pulling in kotlinx-coroutines-play-services for two call sites.
     */
    private suspend fun <T> Task<T>.awaitOrNull(): T? = suspendCancellableCoroutine { cont ->
        addOnSuccessListener { if (cont.isActive) cont.resume(it) }
        addOnFailureListener { if (cont.isActive) cont.resumeWithException(it) }
        addOnCanceledListener { if (cont.isActive) cont.resume(null) }
    }

    private companion object {
        val PERMISSIONS = arrayOf(
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.ACCESS_FINE_LOCATION
        )
        const val MAX_RESULTS = 6
        const val FIX_TIMEOUT_MS = 10_000L
    }
}
