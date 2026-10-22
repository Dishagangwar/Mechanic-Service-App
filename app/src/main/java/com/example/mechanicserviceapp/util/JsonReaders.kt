package com.example.mechanicserviceapp.util

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Small readers for pulling fields off a PostgREST row.
 *
 * Rows arrive as [JsonObject] rather than typed DTOs so the project does not need
 * the kotlinx-serialization compiler plugin for what is a handful of flat shapes.
 * Every reader returns null on a missing, null or wrongly-typed field, which keeps
 * the "this column is genuinely unknown" case — the normal case for this data —
 * from turning into a crash or a silently wrong default.
 */

private fun JsonObject.primitive(key: String): JsonPrimitive? =
    (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }

fun JsonObject.str(key: String): String? =
    primitive(key)?.content?.takeIf { it.isNotBlank() && it != "null" }

fun JsonObject.int(key: String): Int? = primitive(key)?.intOrNull

fun JsonObject.double(key: String): Double? = primitive(key)?.doubleOrNull

fun JsonObject.bool(key: String): Boolean? = primitive(key)?.booleanOrNull

/** Postgres `text[]` comes back as a JSON array of strings. */
fun JsonObject.stringList(key: String): List<String> {
    val array = this[key] as? JsonArray ?: return emptyList()
    return array.mapNotNull { (it as? JsonPrimitive)?.content?.takeIf(String::isNotBlank) }
}

/** Reads a PostgREST response that may be an array of rows or a single object. */
fun JsonElement.asRows(): List<JsonObject> = when (this) {
    is JsonArray -> mapNotNull { it as? JsonObject }
    is JsonObject -> listOf(this)
    else -> emptyList()
}
