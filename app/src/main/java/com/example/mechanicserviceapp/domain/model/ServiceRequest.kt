package com.example.mechanicserviceapp.domain.model

/** A booking the customer is submitting. */
data class ServiceRequest(
    val mechanicId: String,
    val mechanicName: String,
    val serviceId: String?,
    val serviceName: String,
    val customerName: String,
    val phoneNumber: String,
    val vehicleNumber: String,
    val problemDescription: String
)

/**
 * What the server hands back once the row is written.
 *
 * [requestId] is the booking's actual primary key, not a made-up reference. There
 * is deliberately no ETA here: the old mock invented one with `Random.nextInt(20, 60)`
 * before any garage had seen the request. A real ETA can only come from the garage,
 * so it arrives later on [CustomerRequest.etaMinutes] once they accept.
 */
data class ServiceRequestResult(
    val requestId: String,
    val mechanicName: String
)

/** How far along a booking is. Mirrors the `request_status` enum in Postgres. */
enum class RequestStatus(val wireValue: String, val label: String) {
    PENDING("pending", "Waiting for the garage"),
    ACCEPTED("accepted", "Accepted"),
    IN_PROGRESS("in_progress", "Work in progress"),
    COMPLETED("completed", "Completed"),
    CANCELLED("cancelled", "Cancelled"),
    REJECTED("rejected", "Declined by garage");

    /** The customer may still walk away at these points, and only these. */
    val isCancellable: Boolean get() = this == PENDING || this == ACCEPTED

    val isFinished: Boolean get() = this == COMPLETED || this == CANCELLED || this == REJECTED

    companion object {
        fun fromWire(value: String?): RequestStatus =
            entries.firstOrNull { it.wireValue == value } ?: PENDING
    }
}

/**
 * One of the signed-in user's bookings, as the history screen shows it.
 *
 * [mechanicName] and [serviceName] are snapshots stored on the row itself rather
 * than joins, so a booking stays readable even if the garage listing is later
 * edited or its cached coordinates expire.
 */
data class CustomerRequest(
    val id: String,
    val mechanicId: String,
    val mechanicName: String,
    val serviceName: String,
    val vehicleNumber: String,
    val problemDescription: String,
    val status: RequestStatus,
    /** Set by the garage when it accepts. Null while still pending. */
    val etaMinutes: Int?,
    val mechanicNote: String?,
    val createdAt: String,
    /** The review this user already left for this booking, if any. */
    val myRating: Int?,
    val myComment: String?
) {
    val canReview: Boolean get() = status == RequestStatus.COMPLETED && myRating == null
    val hasReview: Boolean get() = myRating != null
}
