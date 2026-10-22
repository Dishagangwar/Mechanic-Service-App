package com.example.mechanicserviceapp.ui.location

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.mechanicserviceapp.domain.model.SearchLocation
import com.example.mechanicserviceapp.domain.repository.LocationRepository
import com.example.mechanicserviceapp.util.Resource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class LocationPickerUiState(
    val results: List<SearchLocation> = emptyList(),
    val lastUsed: SearchLocation? = null,
    val isSearching: Boolean = false,
    val isLocating: Boolean = false,
    val error: String? = null,
    /** Set when a location has been chosen and the screen should close. */
    val chosen: SearchLocation? = null,
    /** Set when the device location was asked for but permission is missing. */
    val needsPermission: Boolean = false
)

@HiltViewModel
class LocationPickerViewModel @Inject constructor(
    private val locationRepository: LocationRepository
) : ViewModel() {

    private val _state = MutableStateFlow(LocationPickerUiState())
    val state: StateFlow<LocationPickerUiState> = _state.asStateFlow()

    private var searchJob: Job? = null

    init {
        viewModelScope.launch {
            _state.update { it.copy(lastUsed = locationRepository.lastUsedLocation()) }
        }
    }

    fun search(query: String) {
        searchJob?.cancel()
        if (query.isBlank()) {
            _state.update { it.copy(results = emptyList(), error = null, isSearching = false) }
            return
        }

        searchJob = viewModelScope.launch {
            _state.update { it.copy(isSearching = true, error = null) }
            when (val result = locationRepository.search(query)) {
                is Resource.Success ->
                    _state.update {
                        it.copy(isSearching = false, results = result.data, error = null)
                    }

                is Resource.Error ->
                    _state.update {
                        it.copy(isSearching = false, results = emptyList(), error = result.message)
                    }

                Resource.Loading -> Unit
            }
        }
    }

    /**
     * Resolve the device's position. The fragment asks for permission first and only
     * calls this once it has been granted, so a failure here is a genuine fix problem
     * rather than a missing grant — except on the race where it was revoked in between,
     * which the repository still guards against.
     */
    fun useDeviceLocation() {
        if (!locationRepository.hasLocationPermission()) {
            _state.update { it.copy(needsPermission = true) }
            return
        }

        viewModelScope.launch {
            _state.update { it.copy(isLocating = true, error = null) }
            when (val result = locationRepository.currentLocation()) {
                is Resource.Success ->
                    _state.update { it.copy(isLocating = false, chosen = result.data) }

                is Resource.Error ->
                    _state.update { it.copy(isLocating = false, error = result.message) }

                Resource.Loading -> Unit
            }
        }
    }

    fun choose(location: SearchLocation) {
        _state.update { it.copy(chosen = location) }
    }

    fun onPermissionPromptShown() {
        _state.update { it.copy(needsPermission = false) }
    }

    fun onErrorShown() {
        _state.update { it.copy(error = null) }
    }
}
