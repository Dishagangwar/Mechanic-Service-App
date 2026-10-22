package com.example.mechanicserviceapp.data.remote

import com.example.mechanicserviceapp.data.remote.dto.MechanicsResponseDto
import com.example.mechanicserviceapp.data.remote.dto.ServiceRequestDto
import com.example.mechanicserviceapp.data.remote.dto.ServiceRequestResponseDto
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.POST

interface MechanicApiService {

    @GET("mechanics.json")
    suspend fun getMechanics(): MechanicsResponseDto

    @POST("service-requests")
    suspend fun submitServiceRequest(
        @Body request: ServiceRequestDto
    ): ServiceRequestResponseDto
}
