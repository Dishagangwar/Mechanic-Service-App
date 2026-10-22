package com.example.mechanicserviceapp.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.model.MechanicCategory
import com.example.mechanicserviceapp.domain.model.SearchLocation
import com.example.mechanicserviceapp.domain.model.SearchRadius
import com.example.mechanicserviceapp.domain.repository.AuthRepository
import com.example.mechanicserviceapp.domain.repository.LocationRepository
import com.example.mechanicserviceapp.domain.repository.MechanicRepository
import com.example.mechanicserviceapp.util.Resource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Home owns the sign-out control, so it owns the state of that request. */
sealed interface SignOutState {
    data object Idle : SignOutState
    data object InProgress : SignOutState
    data object Done : SignOutState
    data class Failed(val message: String) : SignOutState
}

/** What the backend had to say about covering the current area. */
sealed interface CoverageState {
    data object Idle : CoverageState
    data object Checking : CoverageState
    data class Imported(val count: Int) : CoverageState
    data object Failed : CoverageState
}

data class HomeUiState(
    /** Null means we have nowhere to search from yet and the picker should open. */
    val location: SearchLocation? = null,
    val radius: SearchRadius = SearchRadius.Fallback,
    val category: MechanicCategory? = null,
    val query: String = "",
    val mechanics: Resource<List<Mechanic>> = Resource.Loading,
    val coverage: CoverageState = CoverageState.Idle
) {
    val hasFilters: Boolean get() = category != null || query.isNotBlank()
}

@HiltViewModel
class HomeViewModel @Inject constructor(
    private val repository: MechanicRepository,
    private val locationRepository: LocationRepository,
    private val authRepository: AuthRepository
) : ViewModel() {

    private val _state = MutableStateFlow(HomeUiState())
    val state: StateFlow<HomeUiState> = _state.asStateFlow()

    /** Cancelled and replaced whenever the query changes, so stale results can't land. */
    private var loadJob: Job? = null
    private var coverageJob: Job? = null

    init {
        resolveStartingLocation()
    }

    /**
     * Figure out where to search on first launch, without making the user choose if
     * we can avoid it: the location they last used, else the device's own position,
     * else nothing — and then the fragment opens the picker.
     */
    private fun resolveStartingLocation() {
        viewModelScope.launch {
            locationRepository.lastUsedLocation()?.let { setLocation(it, remember = false); return@launch }

            if (locationRepository.hasLocationPermission()) {
                val result = locationRepository.currentLocation()
                if (result is Resource.Success) { setLocation(result.data); return@launch }
            }

            // Nothing to go on. Not an error — the picker is the next step.
            _state.update { it.copy(location = null, mechanics = Resource.Success(emptyList())) }
        }
    }

    fun setLocation(location: SearchLocation, remember: Boolean = true) {
        if (!location.isValid) return
        _state.update { it.copy(location = location, coverage = CoverageState.Idle) }
        if (remember) viewModelScope.launch { locationRepository.rememberLocation(location) }
        load()
        ensureCoverage(location)
    }

    fun setRadius(radius: SearchRadius) {
        if (_state.value.radius == radius) return
        _state.update { it.copy(radius = radius) }
        load()
    }

    fun setCategory(category: MechanicCategory?) {
        if (_state.value.category == category) return
        _state.update { it.copy(category = category) }
        load()
    }

    fun setQuery(query: String) {
        if (_state.value.query == query) return
        _state.update { it.copy(query = query) }
        load()
    }

    fun clearFilters() {
        _state.update { it.copy(category = null, query = "") }
        load()
    }

    fun refresh() {
        val location = _state.value.location ?: return
        load()
        ensureCoverage(location, force = true)
    }

    private fun load() {
        val current = _state.value
        val location = current.location ?: return

        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            repository.getMechanics(
                location = location,
                radiusKm = current.radius.km,
                category = current.category,
                query = current.query.takeIf { it.isNotBlank() }
            ).collect { result -> _state.update { it.copy(mechanics = result) } }
        }
    }

    /**
     * Ask the backend to pull this region in if it has never been fetched.
     *
     * Deliberately *after* [load] rather than before it: where data already exists the
     * list appears immediately and this is a no-op the user never notices. Only a
     * genuinely new region costs a wait, and a failure here is non-fatal — whatever is
     * already cached stays on screen.
     */
    private fun ensureCoverage(location: SearchLocation, force: Boolean = false) {
        coverageJob?.cancel()
        coverageJob = viewModelScope.launch {
            _state.update { it.copy(coverage = CoverageState.Checking) }

            when (val result = repository.ensureCoverage(location, _state.value.radius.km)) {
                is Resource.Success -> {
                    val imported = !result.data.wasCached && result.data.mechanicCount > 0
                    _state.update {
                        it.copy(
                            coverage = if (imported) {
                                CoverageState.Imported(result.data.mechanicCount)
                            } else {
                                CoverageState.Idle
                            }
                        )
                    }
                    // New rows landed, so what we listed a moment ago is already stale.
                    if (imported || force) load()
                }

                is Resource.Error ->
                    _state.update { it.copy(coverage = CoverageState.Failed) }

                Resource.Loading -> Unit
            }
        }
    }

    fun onCoverageNoticeShown() {
        _state.update { it.copy(coverage = CoverageState.Idle) }
    }

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
