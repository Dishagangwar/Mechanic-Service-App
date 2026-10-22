package com.example.mechanicserviceapp.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.repository.AuthRepository
import com.example.mechanicserviceapp.domain.repository.MechanicRepository
import com.example.mechanicserviceapp.util.Resource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Home owns the sign-out control, so it owns the state of that request. */
sealed interface SignOutState {
    data object Idle : SignOutState
    data object InProgress : SignOutState
    data object Done : SignOutState
    data class Failed(val message: String) : SignOutState
}

@HiltViewModel
class HomeViewModel @Inject constructor(
    private val repository: MechanicRepository,
    private val authRepository: AuthRepository
) : ViewModel() {

    private val _state = MutableStateFlow<Resource<List<Mechanic>>>(Resource.Loading)
    val state: StateFlow<Resource<List<Mechanic>>> = _state.asStateFlow()

    init {
        loadMechanics()
    }

    fun loadMechanics() {
        viewModelScope.launch {
            repository.getMechanics().collect { _state.value = it }
        }
    }

    /** Pull to refresh. Same call; the fragment just renders the spinner differently. */
    fun refresh() = loadMechanics()

    /** Whoever is signed in, for the toolbar greeting. Null only if the session vanished. */
    val signedInName: String?
        get() = authRepository.currentUser?.displayName

    private val _signOutState = MutableStateFlow<SignOutState>(SignOutState.Idle)
    val signOutState: StateFlow<SignOutState> = _signOutState.asStateFlow()

    fun signOut() {
        viewModelScope.launch {
            _signOutState.value = SignOutState.InProgress
            _signOutState.value = when (val result = authRepository.signOut()) {
                is Resource.Success -> SignOutState.Done
                is Resource.Error -> SignOutState.Failed(result.message)
                Resource.Loading -> SignOutState.InProgress
            }
        }
    }

    fun onSignOutFailureShown() {
        _signOutState.value = SignOutState.Idle
    }
}
