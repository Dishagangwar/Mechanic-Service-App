package com.example.mechanicserviceapp.domain.repository

import com.example.mechanicserviceapp.domain.model.AuthUser
import com.example.mechanicserviceapp.util.Resource

/**
 * The signed-in user's stored profile.
 *
 * Sign-up writes the name and phone into Supabase user metadata, and a database
 * trigger copies them into a `profiles` row. Reading them back from there is what
 * lets the booking form arrive pre-filled instead of asking for the same two
 * details on every booking.
 */
interface ProfileRepository {

    suspend fun myProfile(): Resource<AuthUser>

    suspend fun updateContactDetails(fullName: String, phoneNumber: String): Resource<Unit>
}
