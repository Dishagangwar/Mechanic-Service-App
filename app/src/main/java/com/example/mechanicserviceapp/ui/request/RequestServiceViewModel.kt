package com.example.mechanicserviceapp.ui.request

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.mechanicserviceapp.domain.model.ServiceOption
import com.example.mechanicserviceapp.domain.model.ServiceRequest
import com.example.mechanicserviceapp.domain.model.ServiceRequestResult
import com.example.mechanicserviceapp.domain.repository.MechanicRepository
import com.example.mechanicserviceapp.domain.repository.ProfileRepository
import com.example.mechanicserviceapp.domain.repository.RequestRepository
import com.example.mechanicserviceapp.util.Resource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Which fields failed validation. Null means that field is fine. */
data class FormErrors(
    val name: String? = null,
    val phone: String? = null,
    val vehicleNumber: String? = null,
    val service: String? = null,
    val problem: String? = null
) {
    val hasErrors: Boolean
        get() = listOf(name, phone, vehicleNumber, service, problem).any { it != null }
}

sealed interface SubmissionState {
    data object Idle : SubmissionState
    data object Submitting : SubmissionState
    data class Success(val result: ServiceRequestResult) : SubmissionState
    data class Failure(val message: String) : SubmissionState
}

@HiltViewModel
class RequestServiceViewModel @Inject constructor(
    private val requestRepository: RequestRepository,
    private val mechanicRepository: MechanicRepository,
    private val profileRepository: ProfileRepository,
    savedStateHandle: SavedStateHandle
) : ViewModel() {

    private val mechanicId: String = savedStateHandle[ARG_MECHANIC_ID]
        ?: error("RequestServiceFragment requires a '$ARG_MECHANIC_ID' argument")

    private val mechanicName: String = savedStateHandle[ARG_MECHANIC_NAME] ?: ""

    /**
     * The service catalog, so the booking can store which service was picked rather
     * than only its name. Loaded once; a failure here is not fatal because
     * `service_id` is nullable and the name is stored on the row either way.
     */
    private var catalog: List<ServiceOption> = emptyList()

    /** Pre-fills the form from the user's profile so they don't retype it every time. */
    private val _prefill = MutableStateFlow<Prefill?>(null)
    val prefill: StateFlow<Prefill?> = _prefill.asStateFlow()

    init {
        viewModelScope.launch {
            when (val result = mechanicRepository.getServiceCatalog()) {
                is Resource.Success -> catalog = result.data
                else -> Unit
            }
        }
        viewModelScope.launch {
            val profile = profileRepository.myProfile()
            if (profile is Resource.Success) {
                _prefill.value = Prefill(
                    name = profile.data.fullName,
                    phone = profile.data.phoneNumber
                )
            }
        }
    }

    private val _errors = MutableStateFlow(FormErrors())
    val errors: StateFlow<FormErrors> = _errors.asStateFlow()

    private val _submission = MutableStateFlow<SubmissionState>(SubmissionState.Idle)
    val submission: StateFlow<SubmissionState> = _submission.asStateFlow()

    fun submit(
        name: String,
        phone: String,
        vehicleNumber: String,
        service: String,
        problem: String
    ) {
        val trimmedName = name.trim()
        val trimmedPhone = phone.trim()
        val trimmedVehicle = vehicleNumber.trim().uppercase()
        val trimmedProblem = problem.trim()

        val errors = validate(trimmedName, trimmedPhone, trimmedVehicle, service, trimmedProblem)
        _errors.value = errors
        if (errors.hasErrors) return

        viewModelScope.launch {
            _submission.value = SubmissionState.Submitting
            val result = requestRepository.submit(
                ServiceRequest(
                    mechanicId = mechanicId,
                    mechanicName = mechanicName,
                    // Matched by name because the form's options come from the garage's
                    // own service list. Null simply means the catalog had no match.
                    serviceId = catalog.firstOrNull { it.name == service }?.id,
                    serviceName = service,
                    customerName = trimmedName,
                    phoneNumber = trimmedPhone,
                    vehicleNumber = trimmedVehicle,
                    problemDescription = trimmedProblem
                )
            )
            _submission.value = when (result) {
                is Resource.Success -> SubmissionState.Success(result.data)
                is Resource.Error -> SubmissionState.Failure(result.message)
                Resource.Loading -> SubmissionState.Submitting
            }
        }
    }

    /** Lets the fragment clear a field's error as soon as the user starts fixing it. */
    fun clearError(field: Field) {
        _errors.value = when (field) {
            Field.NAME -> _errors.value.copy(name = null)
            Field.PHONE -> _errors.value.copy(phone = null)
            Field.VEHICLE -> _errors.value.copy(vehicleNumber = null)
            Field.SERVICE -> _errors.value.copy(service = null)
            Field.PROBLEM -> _errors.value.copy(problem = null)
        }
    }

    fun onFailureShown() {
        _submission.value = SubmissionState.Idle
    }

    private fun validate(
        name: String,
        phone: String,
        vehicle: String,
        service: String,
        problem: String
    ) = FormErrors(
        name = when {
            name.isEmpty() -> "Please enter your name"
            name.length < 2 -> "That name looks too short"
            else -> null
        },
        phone = when {
            phone.isEmpty() -> "Please enter your phone number"
            !phone.matches(PHONE_PATTERN) -> "Enter a valid 10-digit mobile number"
            else -> null
        },
        vehicleNumber = when {
            vehicle.isEmpty() -> "Please enter your vehicle number"
            !vehicle.matches(VEHICLE_PATTERN) -> "Use a format like MH12AB1234"
            else -> null
        },
        service = if (service.isEmpty()) "Please select a service" else null,
        problem = when {
            problem.isEmpty() -> "Please describe the problem"
            problem.length < 10 -> "Add a little more detail (at least 10 characters)"
            else -> null
        }
    )

    /** What we already know about the customer from their profile. */
    data class Prefill(val name: String, val phone: String)

    companion object {
        const val ARG_MECHANIC_ID = "mechanicId"
        const val ARG_MECHANIC_NAME = "mechanicName"
        const val ARG_SERVICES = "services"

        // Indian mobile numbers: 10 digits starting 6-9, optionally +91 / 0 prefixed.
        private val PHONE_PATTERN = Regex("^(\\+91|91|0)?[6-9]\\d{9}$")

        // e.g. MH12AB1234, DL8CAF5030
        private val VEHICLE_PATTERN = Regex("^[A-Z]{2}\\d{1,2}[A-Z]{1,3}\\d{1,4}$")
    }
}

/** Identifies which input the user is currently correcting. */
enum class Field { NAME, PHONE, VEHICLE, SERVICE, PROBLEM }
