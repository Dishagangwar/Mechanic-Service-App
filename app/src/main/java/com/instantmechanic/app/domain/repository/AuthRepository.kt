package com.instantmechanic.app.domain.repository

import com.instantmechanic.app.domain.model.AuthState
import com.instantmechanic.app.domain.model.AuthUser
import com.instantmechanic.app.domain.model.SignUpOutcome
import com.instantmechanic.app.util.Resource
import kotlinx.coroutines.flow.Flow

interface AuthRepository {

    /** Mirrors the stored session for as long as the process lives. Never completes. */
    val authState: Flow<AuthState>

    /** The current user without waiting on the flow, or null when signed out. */
    val currentUser: AuthUser?

    suspend fun signUp(
        email: String,
        password: String,
        fullName: String,
        phoneNumber: String
    ): Resource<SignUpOutcome>

    suspend fun signIn(email: String, password: String): Resource<AuthUser>

    suspend fun signOut(): Resource<Unit>

    /**
     * Permanently deletes the signed-in account and everything that hangs off it, then
     * drops the local session. Play requires this for any app that creates accounts.
     */
    suspend fun deleteAccount(): Resource<Unit>
}
