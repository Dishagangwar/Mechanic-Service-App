package com.example.mechanicserviceapp.domain.model

/**
 * The signed-in person, flattened out of Supabase's `UserInfo` plus the user metadata we
 * attach at sign-up. Only the fields a screen actually renders live here.
 */
data class AuthUser(
    val id: String,
    val email: String,
    val fullName: String,
    val phoneNumber: String
) {
    /** Falls back to the email's local part so the UI always has something to greet. */
    val displayName: String
        get() = fullName.ifBlank { email.substringBefore('@') }
}

/**
 * Whether someone is signed in. [Resolving] is the brief window at launch while Supabase
 * reads the session off disk — the gate screen waits on it instead of flashing sign-in at
 * a user who is already logged in.
 */
sealed interface AuthState {
    data object Resolving : AuthState

    data object SignedOut : AuthState

    data class SignedIn(val user: AuthUser) : AuthState

    /**
     * No Supabase credentials were compiled in, so there is no backend to ask. Surfaced as
     * a state rather than an exception so the app still starts and can explain itself.
     */
    data object NotConfigured : AuthState
}

/**
 * Sign-up ends in one of two places depending on whether the Supabase project has email
 * confirmation switched on.
 */
sealed interface SignUpOutcome {
    /** Confirmation is off: the account is live and already carries a session. */
    data class SignedIn(val user: AuthUser) : SignUpOutcome

    /** Confirmation is on: the account exists but stays dormant until the link is clicked. */
    data class ConfirmationRequired(val email: String) : SignUpOutcome
}
