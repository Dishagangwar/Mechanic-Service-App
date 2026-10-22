package com.example.mechanicserviceapp.data.repository

import com.example.mechanicserviceapp.data.mapper.toDomain
import com.example.mechanicserviceapp.data.remote.MechanicApiService
import com.example.mechanicserviceapp.data.remote.dto.ServiceRequestDto
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.model.ServiceRequest
import com.example.mechanicserviceapp.domain.model.ServiceRequestResult
import com.example.mechanicserviceapp.domain.repository.MechanicRepository
import com.example.mechanicserviceapp.util.Resource
import com.example.mechanicserviceapp.util.toUserMessage
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class MechanicRepositoryImpl @Inject constructor(
    private val api: MechanicApiService
) : MechanicRepository {

    /**
     * The last successful list. The detail screen looks a mechanic up here instead of
     * issuing a second request, which also means rotating the device costs nothing.
     */
    @Volatile
    private var cachedMechanics: List<Mechanic> = emptyList()

    override fun getMechanics(): Flow<Resource<List<Mechanic>>> = flow {
        emit(Resource.Loading)
        try {
            val mechanics = api.getMechanics().mechanics.mapNotNull { it.toDomain() }
            cachedMechanics = mechanics
            emit(Resource.Success(mechanics))
        } catch (e: Exception) {
            emit(Resource.Error(e.toUserMessage(), e))
        }
    }

    override fun getMechanicById(id: String): Flow<Resource<Mechanic>> = flow {
        emit(Resource.Loading)

        cachedMechanics.firstOrNull { it.id == id }?.let {
            emit(Resource.Success(it))
            return@flow
        }

        // Cold start straight into the detail screen (process death, deep link) leaves the
        // cache empty, so fall back to refetching.
        try {
            val mechanics = api.getMechanics().mechanics.mapNotNull { it.toDomain() }
            cachedMechanics = mechanics
            val match = mechanics.firstOrNull { it.id == id }
            if (match != null) {
                emit(Resource.Success(match))
            } else {
                emit(Resource.Error("This garage is no longer available."))
            }
        } catch (e: Exception) {
            emit(Resource.Error(e.toUserMessage(), e))
        }
    }

    override suspend fun submitServiceRequest(
        request: ServiceRequest
    ): Resource<ServiceRequestResult> = try {
        val response = api.submitServiceRequest(
            ServiceRequestDto(
                mechanicId = request.mechanicId,
                customerName = request.customerName,
                phoneNumber = request.phoneNumber,
                vehicleNumber = request.vehicleNumber,
                service = request.service,
                problemDescription = request.problemDescription
            )
        )
        Resource.Success(response.toDomain())
    } catch (e: Exception) {
        Resource.Error(e.toUserMessage(), e)
    }
}
