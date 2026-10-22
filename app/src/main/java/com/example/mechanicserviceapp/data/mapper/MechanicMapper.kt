package com.example.mechanicserviceapp.data.mapper

import com.example.mechanicserviceapp.data.remote.dto.MechanicDto
import com.example.mechanicserviceapp.data.remote.dto.ServiceRequestResponseDto
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.model.ServiceRequestResult

/**
 * DTO -> domain. Every field on the DTO is nullable because a server is free to omit
 * anything; the domain model is not, so defaults are applied here in one place.
 */
fun MechanicDto.toDomain(): Mechanic? {
    // A record with no id or name is not something we can show or navigate to, so drop it
    // rather than rendering a blank card.
    val safeId = id?.takeIf { it.isNotBlank() } ?: return null
    val safeName = name?.takeIf { it.isNotBlank() } ?: return null

    return Mechanic(
        id = safeId,
        name = safeName,
        rating = rating ?: 0.0,
        reviewCount = reviewCount ?: 0,
        distanceKm = distanceKm ?: 0.0,
        location = location.orEmpty(),
        address = address.orEmpty(),
        phone = phone.orEmpty(),
        isOpen = isOpen ?: false,
        workingHours = workingHours ?: "Hours not available",
        services = services.orEmpty()
    )
}

fun ServiceRequestResponseDto.toDomain(): ServiceRequestResult = ServiceRequestResult(
    requestId = requestId.orEmpty(),
    message = message ?: "Your service request has been received.",
    etaMinutes = etaMinutes ?: 0
)
