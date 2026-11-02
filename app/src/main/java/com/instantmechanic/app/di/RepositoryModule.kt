package com.instantmechanic.app.di

import com.instantmechanic.app.data.repository.AuthRepositoryImpl
import com.instantmechanic.app.data.repository.GarageRepositoryImpl
import com.instantmechanic.app.data.repository.LocationRepositoryImpl
import com.instantmechanic.app.data.repository.MechanicRepositoryImpl
import com.instantmechanic.app.data.repository.ProfileRepositoryImpl
import com.instantmechanic.app.data.repository.RequestRepositoryImpl
import com.instantmechanic.app.domain.repository.AuthRepository
import com.instantmechanic.app.domain.repository.GarageRepository
import com.instantmechanic.app.domain.repository.LocationRepository
import com.instantmechanic.app.domain.repository.MechanicRepository
import com.instantmechanic.app.domain.repository.ProfileRepository
import com.instantmechanic.app.domain.repository.RequestRepository
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
