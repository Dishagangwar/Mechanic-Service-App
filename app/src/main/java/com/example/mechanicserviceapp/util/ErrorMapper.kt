package com.example.mechanicserviceapp.util

import io.github.jan.supabase.exceptions.BadRequestRestException
import io.github.jan.supabase.exceptions.HttpRequestException
import io.github.jan.supabase.exceptions.NotFoundRestException
import io.github.jan.supabase.exceptions.UnauthorizedRestException
import io.github.jan.supabase.exceptions.UnknownRestException
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * Turns a raw exception into something worth showing a user.
 *
 * Supabase surfaces failures as `RestException` subclasses rather than Retrofit's
 * `HttpException`, and the messages it carries are written for developers —
 * Postgres error text and policy names. A row level security rejection in
 * particular reads as a constraint violation, which is meaningless to the person
 * holding the phone, so the common ones are translated here.
 */
fun Throwable.toUserMessage(): String = when (this) {
    is UnknownHostException ->
        "No internet connection. Check your network and try again."

    is SocketTimeoutException ->
        "The request timed out. Your connection may be slow."

    is UnauthorizedRestException ->
        "Your session has expired. Please sign in again."

    is NotFoundRestException ->
        "We couldn't find what you were looking for."

    is BadRequestRestException -> friendlyRestMessage(message)

    is UnknownRestException -> friendlyRestMessage(message)

    // Supabase wraps transport-level problems in this.
    is HttpRequestException ->
        "Couldn't reach the server. Check your connection and try again."

    is IOException ->
        "Couldn't reach the server. Check your connection and try again."

    else -> message?.takeIf { it.isNotBlank() }?.let(::friendlyRestMessage)
        ?: "Something went wrong. Please try again."
}

/**
 * Picks readable wording for the server-side rules this app actually relies on.
 * The checks are on message content because PostgREST reports a policy failure and
 * a trigger's `raise exception` through the same exception type.
 */
private fun friendlyRestMessage(raw: String?): String {
    val text = raw?.lowercase().orEmpty()
    return when {
        "row-level security" in text || "violates row-level security" in text ->
            "You're not allowed to do that."

        "may only cancel" in text ->
            "This request can no longer be changed from the app."

        "can no longer be cancelled" in text ->
            "This request has already moved on and can't be cancelled."

        "only the garage" in text ->
            "Only the garage can set an ETA for this request."

        "is final" in text ->
            "This request is already finished."

        "reviews_request_id_key" in text || "duplicate key" in text ->
            "You've already reviewed this request."

        "jwt" in text || "token" in text ->
            "Your session has expired. Please sign in again."

        raw.isNullOrBlank() -> "Something went wrong. Please try again."

        // Anything unrecognised: show it rather than swallow it, but keep it short.
        else -> raw.lines().first().take(140)
    }
}
