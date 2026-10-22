package com.example.mechanicserviceapp.data.repository

import com.example.mechanicserviceapp.domain.model.AuthUser
import com.example.mechanicserviceapp.domain.repository.ProfileRepository
import com.example.mechanicserviceapp.util.Resource
import com.example.mechanicserviceapp.util.SupabaseConfig
import com.example.mechanicserviceapp.util.asRows
import com.example.mechanicserviceapp.util.str
import com.example.mechanicserviceapp.util.toUserMessage
import dagger.Lazy
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.postgrest.Postgrest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ProfileRepositoryImpl @Inject constructor(
    private val postgrestProvider: Lazy<Postgrest>,
    private val authProvider: Lazy<Auth>
) : ProfileRepository {

    private val postgrest: Postgrest get() = postgrestProvider.get()
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun myProfile(): Resource<AuthUser> {
        if (!SupabaseConfig.isConfigured) return Resource.Error(SupabaseConfig.SETUP_MESSAGE)
        val user = authProvider.get().currentUserOrNull()
            ?: return Resource.Error("You are not signed in.")

        return try {
            val rows = postgrest.from("profiles")
                .select { filter { eq("id", user.id) } }
                .data
            val row = json.parseToJsonElement(rows).asRows().firstOrNull()

            // The trigger normally creates this row at sign-up. If it is somehow
            // missing, fall back to the session's own metadata rather than failing:
            // the user is signed in, so the app should still work.
            Resource.Success(
                AuthUser(
                    id = user.id,
                    email = row?.str("email") ?: user.email.orEmpty(),
                    fullName = row?.str("full_name").orEmpty(),
                    phoneNumber = row?.str("phone_number").orEmpty()
                )
            )
        } catch (e: Exception) {
            Resource.Error(e.toUserMessage(), e)
        }
    }

    override suspend fun updateContactDetails(
        fullName: String,
        phoneNumber: String
    ): Resource<Unit> {
        if (!SupabaseConfig.isConfigured) return Resource.Error(SupabaseConfig.SETUP_MESSAGE)
        val user = authProvider.get().currentUserOrNull()
            ?: return Resource.Error("You are not signed in.")

        return try {
            postgrest.from("profiles").update(
                buildJsonObject {
                    put("full_name", fullName.trim())
                    put("phone_number", phoneNumber.trim())
                }
            ) { filter { eq("id", user.id) } }
            Resource.Success(Unit)
        } catch (e: Exception) {
            Resource.Error(e.toUserMessage(), e)
        }
    }
}
