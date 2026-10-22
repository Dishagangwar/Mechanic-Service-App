package com.example.mechanicserviceapp.ui.garage

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.mechanicserviceapp.domain.model.GarageRequest
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.model.RequestStatus
import com.example.mechanicserviceapp.domain.repository.GarageRepository
import com.example.mechanicserviceapp.util.Resource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/** One-shot outcomes that need a message and then clearing. */
sealed interface GarageAction {
    data object Idle : GarageAction
    data object Working : GarageAction
    data class Done(val message: String) : GarageAction
    data class Failed(val message: String) : GarageAction
}

data class GarageUiState(
    val garages: Resource<List<Mechanic>> = Resource.Loading,
    val requests: Resource<List<GarageRequest>> = Resource.Loading,
    val action: GarageAction = GarageAction.Idle
) {
    val hasGarage: Boolean
        get() = (garages as? Resource.Success)?.data?.isNotEmpty() == true

    /** Jobs still needing the garage to do something. */
    val openRequests: List<GarageRequest>
        get() = (requests as? Resource.Success)?.data?.filter { it.isOpen }.orEmpty()
}

@HiltViewModel
class GarageViewModel @Inject constructor(
    private val repository: GarageRepository
) : ViewModel() {

    private val _state = MutableStateFlow(GarageUiState())
    val state: StateFlow<GarageUiState> = _state.asStateFlow()

    init {
        load()
    }

    fun load() {
        viewModelScope.launch {
            repository.myGarages().collect { result ->
                _state.update { it.copy(garages = result) }
            }
        }
        viewModelScope.launch {
            repository.incomingRequests().collect { result ->
                _state.update { it.copy(requests = result) }
            }
        }
    }

    fun accept(request: GarageRequest, etaMinutes: Int, note: String?) {
        run("Accepted — the customer can see your ETA.") {
            repository.accept(request.id, etaMinutes, note)
        }
    }

    fun reject(request: GarageRequest) {
        run("Request declined.") {
            repository.setStatus(request.id, RequestStatus.REJECTED)
        }
    }

    fun start(request: GarageRequest) {
        run("Marked as in progress.") {
            repository.setStatus(request.id, RequestStatus.IN_PROGRESS)
        }
    }

    fun complete(request: GarageRequest) {
        // Completing is what unlocks the customer's ability to rate, which is
        // the only way a rating can ever enter this app.
        run("Job completed — the customer can now rate it.") {
            repository.setStatus(request.id, RequestStatus.COMPLETED)
        }
    }

    fun release(mechanicId: String) {
        run("Garage released.") { repository.release(mechanicId) }
    }

    private fun run(successMessage: String, block: suspend () -> Resource<Unit>) {
        viewModelScope.launch {
            _state.update { it.copy(action = GarageAction.Working) }
            when (val result = block()) {
                is Resource.Success -> {
                    _state.update { it.copy(action = GarageAction.Done(successMessage)) }
                    // Re-read rather than patching locally: the legal transitions
                    // live in the database, so it is the authority on what changed.
                    load()
                }

                is Resource.Error ->
                    _state.update { it.copy(action = GarageAction.Failed(result.message)) }

                Resource.Loading -> Unit
            }
        }
    }

    fun onActionShown() {
        _state.update { it.copy(action = GarageAction.Idle) }
    }
}
