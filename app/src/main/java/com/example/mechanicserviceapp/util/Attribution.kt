package com.example.mechanicserviceapp.util

import com.example.mechanicserviceapp.domain.model.Mechanic

/**
 * Credit for whoever supplied the listings on screen.
 *
 * Every provider this app can be pointed at requires attribution, and they do
 * not require the same one, so it is derived from the rows actually shown rather
 * than hardcoded:
 *
 *  - OpenStreetMap is ODbL and wants "© OpenStreetMap contributors".
 *  - Ola Maps' platform terms require the credit to read "Ola Maps", to be
 *    prominent and legible, and to make clear the data is available under the
 *    Open Database License — which they suggest doing by linking the text to
 *    openstreetmap.org/copyright.
 *  - Google requires its results to be attributed to Google.
 *
 * A mixed result set gets all of the relevant credits, because after a provider
 * switch the table legitimately holds rows from more than one source.
 */
object Attribution {

    const val ODBL_URL = "https://www.openstreetmap.org/copyright"

    private const val OSM = "© OpenStreetMap contributors"
    private const val OLA = "Ola Maps"
    private const val GOOGLE = "Google"

    /** The credit line for a set of listings, or null when there is nothing to credit. */
    fun forMechanics(mechanics: List<Mechanic>): String? {
        val credits = mechanics.map { it.source }.distinct().mapNotNull(::creditFor).distinct()
        if (credits.isEmpty()) return null
        return "Garage data: " + credits.joinToString(" · ")
    }

    fun forSource(source: String): String? = creditFor(source)?.let { "Garage data: $it" }

    /**
     * Whether tapping the credit should open the ODbL page. True for the two
     * sources whose terms point there; Google's attribution is not a link.
     */
    fun linksToOdbl(sources: Collection<String>): Boolean =
        sources.any { it == "osm" || it == "ola" }

    private fun creditFor(source: String): String? = when (source) {
        "osm" -> OSM
        "ola" -> OLA
        "google" -> GOOGLE
        // Owner-entered and hand-seeded rows are the app's own; nothing to credit.
        else -> null
    }
}
