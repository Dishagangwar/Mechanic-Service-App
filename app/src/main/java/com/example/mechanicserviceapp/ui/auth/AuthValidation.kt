package com.example.mechanicserviceapp.ui.auth

/**
 * Field rules shared by the sign-in and sign-up forms. Validating on the client is purely
 * about fast feedback — Supabase enforces its own rules server side regardless.
 */
internal object AuthValidation {

    /** Supabase's own default floor is 6; 8 is the more defensible minimum. */
    const val MIN_PASSWORD_LENGTH = 8

    // Deliberately loose. Anything stricter starts rejecting addresses that really exist,
    // and the confirmation email is the only test that actually counts.
    private val EMAIL_PATTERN = Regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]{2,}$")

    // Indian mobile numbers: 10 digits starting 6-9, optionally +91 / 0 prefixed.
    private val PHONE_PATTERN = Regex("^(\\+91|91|0)?[6-9]\\d{9}$")

    fun email(value: String): String? = when {
        value.isEmpty() -> "Please enter your email"
        !value.matches(EMAIL_PATTERN) -> "Enter a valid email address"
        else -> null
    }

    /** Sign-in only checks for presence — length rules belong on the screen that sets it. */
    fun passwordPresent(value: String): String? =
        if (value.isEmpty()) "Please enter your password" else null

    fun newPassword(value: String): String? = when {
        value.isEmpty() -> "Please choose a password"
        value.length < MIN_PASSWORD_LENGTH ->
            "Use at least $MIN_PASSWORD_LENGTH characters"
        value.none { it.isDigit() } -> "Include at least one number"
        value.none { it.isLetter() } -> "Include at least one letter"
        else -> null
    }

    fun confirmPassword(password: String, confirmation: String): String? = when {
        confirmation.isEmpty() -> "Please re-enter your password"
        confirmation != password -> "Passwords don't match"
        else -> null
    }

    fun fullName(value: String): String? = when {
        value.isEmpty() -> "Please enter your name"
        value.length < 2 -> "That name looks too short"
        else -> null
    }

    fun phone(value: String): String? = when {
        value.isEmpty() -> "Please enter your phone number"
        !value.matches(PHONE_PATTERN) -> "Enter a valid 10-digit mobile number"
        else -> null
    }
}
