package com.example.mechanicserviceapp.domain.model

/**
 * A booking seen from the garage's side of the counter.
 *
 * The difference from [CustomerRequest] is the customer's name and number.
 * A garage cannot do the job without being able to reach whoever booked it,
 * and row level security already limits these rows to the two parties involved.
 */
data class GarageRequest(
    val id: String,
    val mechanicId: String,
    val mechanicName: String,
    val serviceName: String,
    val customerName: String,
    val phoneNumber: String,
    val vehicleNumber: String,
    val problemDescription: String,
    val status: RequestStatus,
    val etaMinutes: Int?,
    val mechanicNote: String?,
    val createdAt: String,
    /** The rating the customer left, once the job is done and rated. */
    val customerRating: Int?,
    val customerComment: String?
) {
    /** Waiting on the garage to say yes or no. */
    val needsDecision: Boolean get() = status == RequestStatus.PENDING

    /** Accepted but not yet started. */
    val canStart: Boolean get() = status == RequestStatus.ACCEPTED

    val canComplete: Boolean get() = status == RequestStatus.IN_PROGRESS

    val isOpen: Boolean get() = !status.isFinished
}
