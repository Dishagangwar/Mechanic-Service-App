package com.example.mechanicserviceapp.domain.model

/** A service booking the customer is submitting. */
data class ServiceRequest(
    val mechanicId: String,
    val customerName: String,
    val phoneNumber: String,
    val vehicleNumber: String,
    val service: String,
    val problemDescription: String
)

/** What the backend hands back once the booking is accepted. */
data class ServiceRequestResult(
    val requestId: String,
    val message: String,
    val etaMinutes: Int
)
