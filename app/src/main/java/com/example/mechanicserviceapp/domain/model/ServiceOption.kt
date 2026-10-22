package com.example.mechanicserviceapp.domain.model

/**
 * An entry in the service catalog.
 *
 * The booking form shows the names a garage offers, but the booking row stores the
 * catalog id as well, so "Oil Change" picked at two different garages is the same
 * service to the database and can actually be reported on.
 */
data class ServiceOption(val id: String, val name: String)
