package com.example.mechanicserviceapp.data.mapper

import com.example.mechanicserviceapp.domain.model.CustomerRequest
import com.example.mechanicserviceapp.domain.model.GarageRequest
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.model.MechanicCategory
import com.example.mechanicserviceapp.domain.model.RequestStatus
import com.example.mechanicserviceapp.util.bool
import com.example.mechanicserviceapp.util.double
import com.example.mechanicserviceapp.util.int
import com.example.mechanicserviceapp.util.str
import com.example.mechanicserviceapp.util.stringList
import kotlinx.serialization.json.JsonObject

/**
 * PostgREST rows -> domain.
 *
 * Only `id` and `name` are required; a row missing either cannot be shown or
 * navigated to, so it is dropped rather than rendered as a blank card. Everything
 * else is allowed to be absent and stays absent — no defaults are invented here,
 * because a "0.0 rating" or a "Closed" badge conjured from a null is worse than an
 * honest gap. Compare the previous version of this file, which defaulted
 * `rating` to 0.0, `isOpen` to false and `workingHours` to "Hours not available".
 */
fun JsonObject.toMechanic(): Mechanic? {
    val id = str("id") ?: return null
    val name = str("name") ?: return null

    return Mechanic(
        id = id,
        name = name,
        nameEn = str("name_en"),
        category = MechanicCategory.fromWire(str("category")),
        rating = double("rating"),
        reviewCount = int("review_count") ?: 0,
        distanceKm = double("distance_km"),
        phone = str("phone"),
        website = str("website"),
        brand = str("brand"),
        addressLine = str("address_line"),
        locality = str("locality"),
        city = str("city"),
        postcode = str("postcode"),
        isOpen = bool("is_open"),
        openingHoursRaw = str("opening_hours_raw"),
        services = stringList("services"),
        hasDeclaredServices = bool("has_declared_services") ?: false,
        source = str("source") ?: "manual",
        ownerId = str("owner_id")
    )
}

/** A row from `my_garage_requests()`. */
fun JsonObject.toGarageRequest(): GarageRequest? {
    val id = str("id") ?: return null

    return GarageRequest(
        id = id,
        mechanicId = str("mechanic_id").orEmpty(),
        mechanicName = str("mechanic_name") ?: "Your garage",
        serviceName = str("service_name") ?: "Service",
        customerName = str("customer_name").orEmpty(),
        phoneNumber = str("phone_number").orEmpty(),
        vehicleNumber = str("vehicle_number").orEmpty(),
        problemDescription = str("problem_description").orEmpty(),
        status = RequestStatus.fromWire(str("status")),
        etaMinutes = int("eta_minutes"),
        mechanicNote = str("mechanic_note"),
        createdAt = str("created_at").orEmpty(),
        customerRating = int("customer_rating"),
        customerComment = str("customer_comment")
    )
}

/** A row from the `my_requests()` function. */
fun JsonObject.toCustomerRequest(): CustomerRequest? {
    val id = str("id") ?: return null

    return CustomerRequest(
        id = id,
        mechanicId = str("mechanic_id").orEmpty(),
        // Snapshot columns, so these are present even for a garage since removed.
        mechanicName = str("mechanic_name") ?: "Unknown garage",
        serviceName = str("service_name") ?: "Service",
        vehicleNumber = str("vehicle_number").orEmpty(),
        problemDescription = str("problem_description").orEmpty(),
        status = RequestStatus.fromWire(str("status")),
        etaMinutes = int("eta_minutes"),
        mechanicNote = str("mechanic_note"),
        createdAt = str("created_at").orEmpty(),
        myRating = int("my_rating"),
        myComment = str("my_comment")
    )
}
