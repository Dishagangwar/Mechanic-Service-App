package com.example.mechanicserviceapp.domain.repository

import com.example.mechanicserviceapp.domain.model.AuthState
import com.example.mechanicserviceapp.domain.model.AuthUser
import com.example.mechanicserviceapp.domain.model.SignUpOutcome
import com.example.mechanicserviceapp.util.Resource
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
}
