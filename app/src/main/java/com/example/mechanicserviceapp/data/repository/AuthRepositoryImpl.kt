package com.example.mechanicserviceapp.data.repository

import com.example.mechanicserviceapp.domain.model.AuthState
import com.example.mechanicserviceapp.domain.model.AuthUser
import com.example.mechanicserviceapp.domain.model.SignUpOutcome
import com.example.mechanicserviceapp.domain.repository.AuthRepository
import com.example.mechanicserviceapp.util.Resource
import com.example.mechanicserviceapp.util.SupabaseConfig
import com.example.mechanicserviceapp.util.toAuthUserMessage
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.SignOutScope
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserInfo
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import javax.inject.Inject
import javax.inject.Singleton
import dagger.Lazy

@Singleton
class AuthRepositoryImpl @Inject constructor(
    /**
     * Lazy on purpose. Building the client needs real credentials, so on an unconfigured
     * build nothing here may resolve it — every entry point checks
     * [SupabaseConfig.isConfigured] before touching this.
     */
    private val authProvider: Lazy<Auth>
) : AuthRepository {

    private val auth: Auth
        get() = authProvider.get()

    override val authState: Flow<AuthState> = flow {
        if (!SupabaseConfig.isConfigured) {
            emit(AuthState.NotConfigured)
            return@flow
        }
        emitAll(auth.sessionStatus.map(::toAuthState))
    }

    override val currentUser: AuthUser?
        get() = if (SupabaseConfig.isConfigured) auth.currentUserOrNull()?.toAuthUser() else null

    override suspend fun signUp(
        email: String,
        password: String,
        fullName: String,
        phoneNumber: String
    ): Resource<SignUpOutcome> {
        if (!SupabaseConfig.isConfigured) return notConfigured()

        return try {
            val created = auth.signUpWith(Email) {
                this.email = email
                this.password = password
                // Lands in auth.users.raw_user_meta_data, which is where the profile fields
                // live until this app grows a real `profiles` table.
                data = buildJsonObject {
                    put(KEY_FULL_NAME, fullName)
                    put(KEY_PHONE, phoneNumber)
                }
            }

            // Supabase only issues a session here when the project has email confirmation
            // switched off. With it on, the account exists but there is nothing to sign in
            // with yet, so send the user to check their inbox instead of into the app.
            val user = auth.currentUserOrNull()
            if (user != null) {
                Resource.Success(SignUpOutcome.SignedIn(user.toAuthUser()))
            } else {
                Resource.Success(SignUpOutcome.ConfirmationRequired(created?.email ?: email))
            }
        } catch (e: Exception) {
            Resource.Error(e.toAuthUserMessage(), e)
        }
    }

    override suspend fun signIn(email: String, password: String): Resource<AuthUser> {
        if (!SupabaseConfig.isConfigured) return notConfigured()

        return try {
            auth.signInWith(Email) {
                this.email = email
                this.password = password
            }
            Resource.Success(auth.currentUserOrNull().toAuthUser(fallbackEmail = email))
        } catch (e: Exception) {
            Resource.Error(e.toAuthUserMessage(), e)
        }
    }

    override suspend fun signOut(): Resource<Unit> {
        if (!SupabaseConfig.isConfigured) return notConfigured()

        return try {
            // LOCAL rather than the default global scope: a global sign-out needs a round
            // trip to revoke tokens everywhere, and if that call fails the local session
            // survives and the user is stuck looking at a signed-in app they asked to leave.
            auth.signOut(SignOutScope.LOCAL)
            Resource.Success(Unit)
        } catch (e: Exception) {
            Resource.Error(e.toAuthUserMessage(), e)
        }
    }

    private fun toAuthState(status: SessionStatus): AuthState = when (status) {
        is SessionStatus.Initializing -> AuthState.Resolving

        is SessionStatus.Authenticated -> AuthState.SignedIn(status.session.user.toAuthUser())

        is SessionStatus.NotAuthenticated -> AuthState.SignedOut

        // The refresh token is stale or the server rejected it. The stored session is no
        // longer usable, so treat it as signed out and make them authenticate again rather
        // than leaving the app in a half-working state.
        is SessionStatus.RefreshFailure -> AuthState.SignedOut
    }

    private fun <T> notConfigured(): Resource<T> = Resource.Error(SupabaseConfig.SETUP_MESSAGE)

    /**
     * A valid session can still carry an incomplete user object, so every field degrades to
     * a blank rather than forcing the caller to juggle nulls.
     */
    private fun UserInfo?.toAuthUser(fallbackEmail: String = ""): AuthUser = AuthUser(
        id = this?.id.orEmpty(),
        email = this?.email?.takeIf { it.isNotBlank() } ?: fallbackEmail,
        fullName = this?.metadataString(KEY_FULL_NAME).orEmpty(),
        phoneNumber = this?.metadataString(KEY_PHONE) ?: this?.phone.orEmpty()
    )

    private fun UserInfo.metadataString(key: String): String? =
        (userMetadata?.get(key) as? JsonPrimitive)?.contentOrNull

    private companion object {
        // Snake case to match the convention Supabase itself uses for metadata keys.
        const val KEY_FULL_NAME = "full_name"
        const val KEY_PHONE = "phone_number"
    }
}
