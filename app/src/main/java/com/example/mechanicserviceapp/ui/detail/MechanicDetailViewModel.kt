package com.example.mechanicserviceapp.ui.detail

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.repository.AuthRepository
import com.example.mechanicserviceapp.domain.repository.GarageRepository
import com.example.mechanicserviceapp.domain.repository.MechanicRepository
import com.example.mechanicserviceapp.util.Resource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Outcome of claiming or releasing a listing. */
sealed interface ClaimState {
    data object Idle : ClaimState
    data object Working : ClaimState
    data class Done(val message: String) : ClaimState
    data class Failed(val message: String) : ClaimState
}

@HiltViewModel
class MechanicDetailViewModel @Inject constructor(
    private val repository: MechanicRepository,
    private val garageRepository: GarageRepository,
    private val authRepository: AuthRepository,
    savedStateHandle: SavedStateHandle
) : ViewModel() {

    /** Used to tell "yours" apart from "somebody else's" on the same screen. */
    val currentUserId: String? get() = authRepository.currentUser?.id

    private val _claim = MutableStateFlow<ClaimState>(ClaimState.Idle)
    val claim: StateFlow<ClaimState> = _claim.asStateFlow()

    fun claim(mechanicId: String) = runClaim("You now manage this garage.") {
        garageRepository.claim(mechanicId)
    }

    fun release(mechanicId: String) = runClaim("Garage released.") {
        garageRepository.release(mechanicId)
    }

    private fun runClaim(message: String, block: suspend () -> Resource<Unit>) {
        viewModelScope.launch {
            _claim.value = ClaimState.Working
            _claim.value = when (val result = block()) {
                is Resource.Success -> ClaimState.Done(message)
                is Resource.Error -> ClaimState.Failed(result.message)
                Resource.Loading -> ClaimState.Working
            }
            // Ownership changed, so the row we are rendering is stale.
            if (_claim.value is ClaimState.Done) load()
        }
    }

    fun onClaimShown() {
        _claim.value = ClaimState.Idle
    }

    private val mechanicId: String = savedStateHandle[ARG_MECHANIC_ID]
        ?: error("MechanicDetailFragment requires a '$ARG_MECHANIC_ID' argument")

    private val _state = MutableStateFlow<Resource<Mechanic>>(Resource.Loading)
    val state: StateFlow<Resource<Mechanic>> = _state.asStateFlow()

    init {
        load()
    }

    fun load() {
        viewModelScope.launch {
            repository.getMechanicById(mechanicId).collect { _state.value = it }
        }
    }

    companion object {
        const val ARG_MECHANIC_ID = "mechanicId"
    }
}
