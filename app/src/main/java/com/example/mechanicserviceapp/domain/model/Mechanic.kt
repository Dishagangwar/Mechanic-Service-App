package com.example.mechanicserviceapp.domain.model

/**
 * A garage as the UI cares about it.
 *
 * Several fields are nullable, and that is the point. This data describes real
 * businesses pulled from a public map database, where most records are incomplete.
 * A garage with no known phone number renders no call button; one with no known
 * opening hours reports [isOpen] as null and the UI says so, rather than printing
 * a confident "Closed" it has no basis for. The previous version of this model
 * made every field non-null by inventing defaults, which is how a demo ends up
 * looking more certain than the data behind it.
 */
data class Mechanic(
    val id: String,
    val name: String,
    /** Latin-script name where the primary one is in Devanagari. */
    val nameEn: String?,
    val category: MechanicCategory,
    /** Null until somebody has actually reviewed this garage. */
    val rating: Double?,
    val reviewCount: Int,
    /** Computed from the search location, so null only if the row has no coordinates. */
    val distanceKm: Double?,
    val phone: String?,
    val website: String?,
    val brand: String?,
    val addressLine: String?,
    val locality: String?,
    val city: String?,
    val postcode: String?,
    /** Null when nobody has recorded this garage's hours. Not "closed". */
    val isOpen: Boolean?,
    /** The provider's raw hours string, shown verbatim when it could not be parsed. */
    val openingHoursRaw: String?,
    val services: List<String>,
    /** True when the garage itself listed its services, rather than us inferring them. */
    val hasDeclaredServices: Boolean,
    val source: String
) {
    /** What to show as the heading. */
    val displayName: String get() = name

    /** A second line for the name, only when it adds something. */
    val secondaryName: String? get() = nameEn?.takeIf { it != name }

    /** Best available single-line location. */
    val displayLocation: String?
        get() = listOfNotNull(locality, city).distinct().joinToString(", ").ifBlank { null }

    val fullAddress: String?
        get() = listOfNotNull(addressLine, locality, city, postcode)
            .distinct().joinToString(", ").ifBlank { null }

    val hasPhone: Boolean get() = !phone.isNullOrBlank()
}

/**
 * What kind of vehicle the place works on. Maps to the `mechanic_category` enum in
 * Postgres, and drives the filter chips on the list screen.
 */
enum class MechanicCategory(val wireValue: String, val label: String) {
    CAR("car", "Car"),
    MOTORCYCLE("motorcycle", "Two wheeler"),
    TYRES("tyres", "Tyres"),
    PARTS("parts", "Parts & accessories");

    companion object {
        fun fromWire(value: String?): MechanicCategory =
            entries.firstOrNull { it.wireValue == value } ?: CAR
    }
}
