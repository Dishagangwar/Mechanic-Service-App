package com.example.mechanicserviceapp.domain.repository

import com.example.mechanicserviceapp.domain.model.SearchLocation
import com.example.mechanicserviceapp.util.Resource

/**
 * Turning "where am I" and "where is this place" into coordinates.
 *
 * Geocoding uses Android's built-in [android.location.Geocoder], which needs no API
 * key and no extra dependency — worth preferring over a paid places autocomplete for
 * what is only a city/area lookup.
 */
interface LocationRepository {

    /** True once the user has granted either coarse or fine location access. */
    fun hasLocationPermission(): Boolean

    /**
     * True only for precise access. Coarse-only is deliberately supported, but the
     * platform fuzzes it to roughly a 1-2 km grid, so it is worth knowing which one
     * we have when choosing how hard to work for a fix and what to tell the user.
     */
    fun hasPreciseLocationPermission(): Boolean

    /**
     * The device's current position, reverse-geocoded to a readable label.
     * Fails with a message if permission is missing or no fix can be obtained.
     */
    suspend fun currentLocation(): Resource<SearchLocation>

    /** Place-name lookup: "Kolhapur", "Baner Pune", a pincode. */
    suspend fun search(query: String): Resource<List<SearchLocation>>

    /** The last location this user searched from, read back from their profile. */
    suspend fun lastUsedLocation(): SearchLocation?

    /** Remembers the location so the next launch skips the picker. */
    suspend fun rememberLocation(location: SearchLocation)
}
