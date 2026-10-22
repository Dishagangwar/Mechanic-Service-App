package com.example.mechanicserviceapp.ui.detail

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.repository.MechanicRepository
import com.example.mechanicserviceapp.util.Resource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class MechanicDetailViewModel @Inject constructor(
    private val repository: MechanicRepository,
    savedStateHandle: SavedStateHandle
) : ViewModel() {

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
