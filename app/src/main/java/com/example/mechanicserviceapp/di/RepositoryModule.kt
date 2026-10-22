package com.example.mechanicserviceapp.di

import com.example.mechanicserviceapp.data.repository.AuthRepositoryImpl
import com.example.mechanicserviceapp.data.repository.GarageRepositoryImpl
import com.example.mechanicserviceapp.data.repository.LocationRepositoryImpl
import com.example.mechanicserviceapp.data.repository.MechanicRepositoryImpl
import com.example.mechanicserviceapp.data.repository.ProfileRepositoryImpl
import com.example.mechanicserviceapp.data.repository.RequestRepositoryImpl
import com.example.mechanicserviceapp.domain.repository.AuthRepository
import com.example.mechanicserviceapp.domain.repository.GarageRepository
import com.example.mechanicserviceapp.domain.repository.LocationRepository
import com.example.mechanicserviceapp.domain.repository.MechanicRepository
import com.example.mechanicserviceapp.domain.repository.ProfileRepository
import com.example.mechanicserviceapp.domain.repository.RequestRepository
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class RepositoryModule {

    @Binds
    @Singleton
    abstract fun bindMechanicRepository(impl: MechanicRepositoryImpl): MechanicRepository

    @Binds
    @Singleton
    abstract fun bindAuthRepository(impl: AuthRepositoryImpl): AuthRepository

    @Binds
    @Singleton
    abstract fun bindRequestRepository(impl: RequestRepositoryImpl): RequestRepository

    @Binds
    @Singleton
    abstract fun bindLocationRepository(impl: LocationRepositoryImpl): LocationRepository

    @Binds
    @Singleton
    abstract fun bindProfileRepository(impl: ProfileRepositoryImpl): ProfileRepository

    @Binds
    @Singleton
    abstract fun bindGarageRepository(impl: GarageRepositoryImpl): GarageRepository
}
