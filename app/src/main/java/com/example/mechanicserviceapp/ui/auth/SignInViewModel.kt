package com.example.mechanicserviceapp.ui.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.mechanicserviceapp.domain.model.AuthUser
import com.example.mechanicserviceapp.domain.repository.AuthRepository
import com.example.mechanicserviceapp.util.Resource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Which fields failed validation. Null means that field is fine. */
data class SignInErrors(
    val email: String? = null,
    val password: String? = null
) {
    val hasErrors: Boolean
        get() = email != null || password != null
}

sealed interface SignInState {
    data object Idle : SignInState
    data object Submitting : SignInState
    data class Success(val user: AuthUser) : SignInState
    data class Failure(val message: String) : SignInState
}

/** Identifies which input the user is currently correcting. */
enum class SignInField { EMAIL, PASSWORD }

@HiltViewModel
class SignInViewModel @Inject constructor(
    private val repository: AuthRepository
) : ViewModel() {

    private val _errors = MutableStateFlow(SignInErrors())
    val errors: StateFlow<SignInErrors> = _errors.asStateFlow()

    private val _state = MutableStateFlow<SignInState>(SignInState.Idle)
    val state: StateFlow<SignInState> = _state.asStateFlow()

    fun signIn(email: String, password: String) {
        // Emails get pasted with stray whitespace and autocapitalised constantly; passwords
        // are taken exactly as typed, since a space may well be part of one.
        val trimmedEmail = email.trim().lowercase()

        val errors = SignInErrors(
            email = AuthValidation.email(trimmedEmail),
            password = AuthValidation.passwordPresent(password)
        )
        _errors.value = errors
        if (errors.hasErrors) return

        viewModelScope.launch {
            _state.value = SignInState.Submitting
            _state.value = when (val result = repository.signIn(trimmedEmail, password)) {
                is Resource.Success -> SignInState.Success(result.data)
                is Resource.Error -> SignInState.Failure(result.message)
                Resource.Loading -> SignInState.Submitting
            }
        }
    }

    /** Lets the fragment clear a field's error as soon as the user starts fixing it. */
    fun clearError(field: SignInField) {
        _errors.value = when (field) {
            SignInField.EMAIL -> _errors.value.copy(email = null)
            SignInField.PASSWORD -> _errors.value.copy(password = null)
        }
    }

    fun onFailureShown() {
        _state.value = SignInState.Idle
    }
}
