package com.example.mechanicserviceapp.util

/**
 * Wraps anything that is loaded asynchronously so the UI can render loading, success and
 * error from a single stream instead of juggling three separate flags.
 */
sealed interface Resource<out T> {
    data object Loading : Resource<Nothing>

    data class Success<T>(val data: T) : Resource<T>

    data class Error(
        val message: String,
        val cause: Throwable? = null
    ) : Resource<Nothing>
}
