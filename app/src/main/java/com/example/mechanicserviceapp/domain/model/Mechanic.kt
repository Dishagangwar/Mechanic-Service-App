package com.example.mechanicserviceapp.domain.model

/**
 * A garage/mechanic as the UI cares about it. Kept separate from the network DTO so a
 * change in the API payload does not ripple through the screens.
 */
data class Mechanic(
    val id: String,
    val name: String,
    val rating: Double,
    val reviewCount: Int,
    val distanceKm: Double,
    val location: String,
    val address: String,
    val phone: String,
    val isOpen: Boolean,
    val workingHours: String,
    val services: List<String>
)
