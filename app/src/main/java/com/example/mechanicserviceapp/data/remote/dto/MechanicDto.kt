package com.example.mechanicserviceapp.data.remote.dto

import com.squareup.moshi.Json
import com.squareup.moshi.JsonClass

@JsonClass(generateAdapter = false)
data class MechanicsResponseDto(
    @param:Json(name = "mechanics") val mechanics: List<MechanicDto>
)

@JsonClass(generateAdapter = false)
data class MechanicDto(
    @param:Json(name = "id") val id: String?,
    @param:Json(name = "name") val name: String?,
    @param:Json(name = "rating") val rating: Double?,
    @param:Json(name = "review_count") val reviewCount: Int?,
    @param:Json(name = "distance_km") val distanceKm: Double?,
    @param:Json(name = "location") val location: String?,
    @param:Json(name = "address") val address: String?,
    @param:Json(name = "phone") val phone: String?,
    @param:Json(name = "is_open") val isOpen: Boolean?,
    @param:Json(name = "working_hours") val workingHours: String?,
    @param:Json(name = "services") val services: List<String>?
)
