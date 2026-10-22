package com.example.mechanicserviceapp.di

import com.example.mechanicserviceapp.data.repository.AuthRepositoryImpl
import com.example.mechanicserviceapp.data.repository.MechanicRepositoryImpl
import com.example.mechanicserviceapp.domain.repository.AuthRepository
import com.example.mechanicserviceapp.domain.repository.MechanicRepository
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
    abstract fun bindMechanicRepository(
        impl: MechanicRepositoryImpl
    ): MechanicRepository

    @Binds
    @Singleton
    abstract fun bindAuthRepository(
        impl: AuthRepositoryImpl
    ): AuthRepository
}
