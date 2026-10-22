package com.example.mechanicserviceapp.domain.repository

import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.model.ServiceRequest
import com.example.mechanicserviceapp.domain.model.ServiceRequestResult
import com.example.mechanicserviceapp.util.Resource
import kotlinx.coroutines.flow.Flow

interface MechanicRepository {

    /** Emits [Resource.Loading] first, then success or error. */
    fun getMechanics(): Flow<Resource<List<Mechanic>>>

    fun getMechanicById(id: String): Flow<Resource<Mechanic>>

    suspend fun submitServiceRequest(request: ServiceRequest): Resource<ServiceRequestResult>
}
