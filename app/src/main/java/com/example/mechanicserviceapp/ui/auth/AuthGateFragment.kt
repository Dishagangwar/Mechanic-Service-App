package com.example.mechanicserviceapp.ui.auth

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.core.view.isVisible
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.navigation.fragment.findNavController
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.FragmentAuthGateBinding
import com.example.mechanicserviceapp.domain.model.AuthState
import com.example.mechanicserviceapp.util.SupabaseConfig
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch

/**
 * The start destination. Supabase restores the stored session asynchronously, so something
 * has to be on screen while that happens — routing from here keeps every other screen free
 * of session checks.
 */
@AndroidEntryPoint
class AuthGateFragment : Fragment() {

    private var _binding: FragmentAuthGateBinding? = null
    private val binding get() = _binding!!

    private val viewModel: AuthGateViewModel by viewModels()

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentAuthGateBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.authState.collect(::route)
            }
        }
    }

    private fun route(state: AuthState) {
        // The flow keeps emitting for the life of the process, but this fragment is popped
        // the moment it routes, so a late emission must not navigate a second time.
        if (findNavController().currentDestination?.id != R.id.authGateFragment) return

        when (state) {
            is AuthState.Resolving -> Unit

            is AuthState.SignedIn ->
                findNavController().navigate(R.id.action_gate_to_home)

            is AuthState.SignedOut ->
                findNavController().navigate(R.id.action_gate_to_signIn)

            // Nothing to route to — there is no backend configured. Stay put and say so,
            // which beats a crash whose only explanation is in logcat.
            is AuthState.NotConfigured -> showSetupRequired()
        }
    }

    private fun showSetupRequired() {
        binding.loadingContainer.isVisible = false
        with(binding.stateView) {
            stateContainer.isVisible = true
            stateIcon.setImageResource(R.drawable.ic_error)
            stateTitle.text = getString(R.string.setup_required_title)
            stateMessage.text = SupabaseConfig.SETUP_MESSAGE
            stateRetryButton.isVisible = false
        }
    }

    override fun onDestroyView() {
        _binding = null
        super.onDestroyView()
    }
}
