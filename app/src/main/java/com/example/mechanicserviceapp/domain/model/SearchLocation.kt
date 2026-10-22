package com.example.mechanicserviceapp.domain.model

/**
 * Where the user is searching from. Everything about finding a garage hangs off
 * this: the app has no built-in city and no default region.
 *
 * It comes from one of three places — the device's location, a place the user
 * typed, or the last location stored on their profile.
 */
data class SearchLocation(
    val latitude: Double,
    val longitude: Double,
    /** Human-readable, for the location bar: "Kothrud, Pune" or "Current location". */
    val label: String,
    val origin: Origin = Origin.MANUAL
) {
    enum class Origin { DEVICE, SEARCHED, SAVED, MANUAL }

    val isValid: Boolean
        get() = latitude in -90.0..90.0 && longitude in -180.0..180.0 &&
            !(latitude == 0.0 && longitude == 0.0)
}

/** Radius options offered on the list screen. */
enum class SearchRadius(val km: Int, val label: String) {
    NEAR(5, "5 km"),
    DEFAULT(10, "10 km"),
    WIDE(25, "25 km");

    companion object {
        val Fallback = DEFAULT
        fun fromKm(km: Int): SearchRadius = entries.firstOrNull { it.km == km } ?: Fallback
    }
}
