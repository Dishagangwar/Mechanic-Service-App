package com.example.mechanicserviceapp.util

import retrofit2.HttpException
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * Turns a raw exception into something worth showing a user. Network stacks throw a lot of
 * different types for what is, to the person holding the phone, the same problem.
 */
fun Throwable.toUserMessage(): String = when (this) {
    is UnknownHostException ->
        "No internet connection. Check your network and try again."

    is SocketTimeoutException ->
        "The request timed out. Your connection may be slow."

    is HttpException -> when (code()) {
        in 500..599 -> "The server is having trouble right now. Please try again shortly."
        404 -> "We couldn't find what you were looking for."
        else -> "Request failed (HTTP ${code()}). Please try again."
    }

    is IOException ->
        "Couldn't reach the server. Check your connection and try again."

    else ->
        message ?: "Something went wrong. Please try again."
}
