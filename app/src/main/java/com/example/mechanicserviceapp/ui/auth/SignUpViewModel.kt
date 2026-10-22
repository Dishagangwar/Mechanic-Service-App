package com.example.mechanicserviceapp.ui.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.mechanicserviceapp.domain.model.AuthUser
import com.example.mechanicserviceapp.domain.model.SignUpOutcome
import com.example.mechanicserviceapp.domain.repository.AuthRepository
import com.example.mechanicserviceapp.util.Resource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Which fields failed validation. Null means that field is fine. */
data class SignUpErrors(
    val fullName: String? = null,
    val email: String? = null,
    val phone: String? = null,
    val password: String? = null,
    val confirmPassword: String? = null
) {
    val hasErrors: Boolean
        get() = listOf(fullName, email, phone, password, confirmPassword).any { it != null }
}

sealed interface SignUpState {
    data object Idle : SignUpState
    data object Submitting : SignUpState

    /** Confirmation is off on the Supabase project, so they are already in. */
    data class Success(val user: AuthUser) : SignUpState

    /** Account created, but it needs the emailed link before it can sign in. */
    data class ConfirmationRequired(val email: String) : SignUpState

    data class Failure(val message: String) : SignUpState
}

/** Identifies which input the user is currently correcting. */
enum class SignUpField { NAME, EMAIL, PHONE, PASSWORD, CONFIRM_PASSWORD }

@HiltViewModel
class SignUpViewModel @Inject constructor(
    private val repository: AuthRepository
) : ViewModel() {

    private val _errors = MutableStateFlow(SignUpErrors())
    val errors: StateFlow<SignUpErrors> = _errors.asStateFlow()

    private val _state = MutableStateFlow<SignUpState>(SignUpState.Idle)
    val state: StateFlow<SignUpState> = _state.asStateFlow()

    fun signUp(
        fullName: String,
        email: String,
        phone: String,
        password: String,
        confirmPassword: String
    ) {
        val trimmedName = fullName.trim()
        val trimmedEmail = email.trim().lowercase()
        val trimmedPhone = phone.trim()

        val errors = SignUpErrors(
            fullName = AuthValidation.fullName(trimmedName),
            email = AuthValidation.email(trimmedEmail),
            phone = AuthValidation.phone(trimmedPhone),
            password = AuthValidation.newPassword(password),
            confirmPassword = AuthValidation.confirmPassword(password, confirmPassword)
        )
        _errors.value = errors
        if (errors.hasErrors) return

        viewModelScope.launch {
            _state.value = SignUpState.Submitting
            val result = repository.signUp(
                email = trimmedEmail,
                password = password,
                fullName = trimmedName,
                phoneNumber = trimmedPhone
            )
            _state.value = when (result) {
                is Resource.Success -> when (val outcome = result.data) {
                    is SignUpOutcome.SignedIn -> SignUpState.Success(outcome.user)
                    is SignUpOutcome.ConfirmationRequired ->
                        SignUpState.ConfirmationRequired(outcome.email)
                }

                is Resource.Error -> SignUpState.Failure(result.message)
                Resource.Loading -> SignUpState.Submitting
            }
        }
    }

    /** Lets the fragment clear a field's error as soon as the user starts fixing it. */
    fun clearError(field: SignUpField) {
        _errors.value = when (field) {
            SignUpField.NAME -> _errors.value.copy(fullName = null)
            SignUpField.EMAIL -> _errors.value.copy(email = null)
            SignUpField.PHONE -> _errors.value.copy(phone = null)
            // Editing either half of the pair can only fix the mismatch, so clear both.
            SignUpField.PASSWORD -> _errors.value.copy(password = null, confirmPassword = null)
            SignUpField.CONFIRM_PASSWORD -> _errors.value.copy(confirmPassword = null)
        }
    }

    fun onFailureShown() {
        _state.value = SignUpState.Idle
    }
}
