package com.example.mechanicserviceapp.ui.auth

import androidx.lifecycle.ViewModel
import com.example.mechanicserviceapp.domain.model.AuthState
import com.example.mechanicserviceapp.domain.repository.AuthRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject

/**
 * Backs the launch screen that decides between sign-in and home. It only forwards the
 * session; the fragment does the navigating.
 */
@HiltViewModel
class AuthGateViewModel @Inject constructor(
    repository: AuthRepository
) : ViewModel() {

    val authState: Flow<AuthState> = repository.authState
}
