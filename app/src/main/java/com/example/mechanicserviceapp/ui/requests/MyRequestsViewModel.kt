package com.example.mechanicserviceapp.ui.requests

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.mechanicserviceapp.domain.model.CustomerRequest
import com.example.mechanicserviceapp.domain.repository.RequestRepository
import com.example.mechanicserviceapp.util.Resource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/** One-shot outcomes that need a snackbar and then clearing. */
sealed interface RequestAction {
    data object Idle : RequestAction
    data object Working : RequestAction
    data class Cancelled(val requestId: String) : RequestAction
    data object Reviewed : RequestAction
    data class Failed(val message: String) : RequestAction
}

data class MyRequestsUiState(
    val requests: Resource<List<CustomerRequest>> = Resource.Loading,
    val action: RequestAction = RequestAction.Idle
)

@HiltViewModel
class MyRequestsViewModel @Inject constructor(
    private val repository: RequestRepository
) : ViewModel() {

    private val _state = MutableStateFlow(MyRequestsUiState())
    val state: StateFlow<MyRequestsUiState> = _state.asStateFlow()

    init {
        load()
    }

    fun load() {
        viewModelScope.launch {
            repository.myRequests().collect { result ->
                _state.update { it.copy(requests = result) }
            }
        }
    }

    fun cancel(requestId: String) {
        viewModelScope.launch {
            _state.update { it.copy(action = RequestAction.Working) }
            when (val result = repository.cancel(requestId)) {
                is Resource.Success -> {
                    _state.update { it.copy(action = RequestAction.Cancelled(requestId)) }
                    // The row's status changed server-side; re-read rather than guessing
                    // locally, since the transition rules live in the database.
                    load()
                }

                is Resource.Error ->
                    _state.update { it.copy(action = RequestAction.Failed(result.message)) }

                Resource.Loading -> Unit
            }
        }
    }

    fun submitReview(request: CustomerRequest, rating: Int, comment: String?) {
        viewModelScope.launch {
            _state.update { it.copy(action = RequestAction.Working) }
            val result = repository.review(
                requestId = request.id,
                mechanicId = request.mechanicId,
                rating = rating,
                comment = comment
            )
            when (result) {
                is Resource.Success -> {
                    _state.update { it.copy(action = RequestAction.Reviewed) }
                    load()
                }

                is Resource.Error ->
                    _state.update { it.copy(action = RequestAction.Failed(result.message)) }

                Resource.Loading -> Unit
            }
        }
    }

    fun onActionShown() {
        _state.update { it.copy(action = RequestAction.Idle) }
    }
}
