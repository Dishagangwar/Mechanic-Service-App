package com.example.mechanicserviceapp.util

import io.github.jan.supabase.auth.exception.AuthErrorCode
import io.github.jan.supabase.auth.exception.AuthRestException
import io.github.jan.supabase.auth.exception.AuthSessionMissingException
import io.github.jan.supabase.auth.exception.AuthWeakPasswordException
import io.github.jan.supabase.exceptions.HttpRequestException

/**
 * Supabase reports failures as error codes rather than prose fit for a screen. Everything
 * it doesn't recognise falls through to [toUserMessage], which already handles the network
 * layer's exception zoo.
 */
fun Throwable.toAuthUserMessage(): String = when (this) {
    is AuthWeakPasswordException ->
        "That password is too weak. Use at least 8 characters."

    is AuthSessionMissingException ->
        "Your session has expired. Please sign in again."

    is AuthRestException -> when (errorCode) {
        AuthErrorCode.InvalidCredentials ->
            "That email and password don't match. Please try again."

        AuthErrorCode.EmailNotConfirmed ->
            "Confirm your email first — check your inbox for the link we sent."

        AuthErrorCode.EmailExists, AuthErrorCode.UserAlreadyExists ->
            "An account already exists for that email. Try signing in instead."

        AuthErrorCode.WeakPassword ->
            "That password is too weak. Use at least 8 characters."

        AuthErrorCode.UserNotFound ->
            "We couldn't find an account for that email."

        AuthErrorCode.UserBanned ->
            "This account has been suspended. Please contact support."

        AuthErrorCode.SignupDisabled, AuthErrorCode.EmailProviderDisabled ->
            "New sign-ups are currently disabled for this app."

        AuthErrorCode.OverRequestRateLimit, AuthErrorCode.OverEmailSendRateLimit ->
            "Too many attempts. Wait a minute and try again."

        AuthErrorCode.ValidationFailed ->
            "Check the details you entered and try again."

        // Anything else: Supabase's own description is usually readable enough.
        else -> errorDescription.ifBlank {
            "Couldn't complete that request. Please try again."
        }
    }

    // Ktor's wrapper for a connection that never got off the ground.
    is HttpRequestException ->
        "Couldn't reach the server. Check your connection and try again."

    else -> toUserMessage()
}
