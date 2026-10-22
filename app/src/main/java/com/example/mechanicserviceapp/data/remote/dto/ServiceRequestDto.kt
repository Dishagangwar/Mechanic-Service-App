package com.example.mechanicserviceapp.data.remote.dto

import com.squareup.moshi.Json
import com.squareup.moshi.JsonClass

@JsonClass(generateAdapter = false)
data class ServiceRequestDto(
    @param:Json(name = "mechanic_id") val mechanicId: String,
    @param:Json(name = "customer_name") val customerName: String,
    @param:Json(name = "phone_number") val phoneNumber: String,
    @param:Json(name = "vehicle_number") val vehicleNumber: String,
    @param:Json(name = "service") val service: String,
    @param:Json(name = "problem_description") val problemDescription: String
)

@JsonClass(generateAdapter = false)
data class ServiceRequestResponseDto(
    @param:Json(name = "request_id") val requestId: String?,
    @param:Json(name = "message") val message: String?,
    @param:Json(name = "eta_minutes") val etaMinutes: Int?
)
