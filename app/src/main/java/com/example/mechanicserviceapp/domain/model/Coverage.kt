package com.example.mechanicserviceapp.domain.model

/**
 * The result of asking the backend to pull in a region it has not seen before.
 *
 * This is what makes the app work anywhere rather than in the cities that happened
 * to be seeded. The distinction between [imported] zero because the region was
 * already cached and zero because the region genuinely has no garages matters to
 * the empty state, so both are reported.
 */
data class CoverageResult(
    /** The geohash cell the backend treated as "this region". */
    val tile: String,
    /** True when this region had already been fetched and nothing was re-requested. */
    val wasCached: Boolean,
    /** How many garages the provider returned for the region. */
    val mechanicCount: Int
)
