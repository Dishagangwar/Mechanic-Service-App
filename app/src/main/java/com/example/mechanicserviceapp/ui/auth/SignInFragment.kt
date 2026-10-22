package com.example.mechanicserviceapp.ui.auth

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.core.view.isVisible
import androidx.core.widget.doOnTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.navigation.fragment.findNavController
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.FragmentSignInBinding
import com.google.android.material.snackbar.Snackbar
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch

@AndroidEntryPoint
class SignInFragment : Fragment() {

    private var _binding: FragmentSignInBinding? = null
    private val binding get() = _binding!!

    private val viewModel: SignInViewModel by viewModels()

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentSignInBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        binding.signInButton.setOnClickListener { submit() }
        binding.goToSignUpButton.setOnClickListener {
            findNavController().navigate(R.id.action_signIn_to_signUp)
        }

        // Wipe a field's error as soon as the user starts correcting it.
        binding.emailInput.doOnTextChanged { _, _, _, _ ->
            viewModel.clearError(SignInField.EMAIL)
        }
        binding.passwordInput.doOnTextChanged { _, _, _, _ ->
            viewModel.clearError(SignInField.PASSWORD)
        }

        observeErrors()
        observeState()
    }

    private fun submit() {
        viewModel.signIn(
            email = binding.emailInput.text?.toString().orEmpty(),
            password = binding.passwordInput.text?.toString().orEmpty()
        )
    }

    private fun observeErrors() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.errors.collect { errors ->
                    binding.emailLayout.error = errors.email
                    binding.passwordLayout.error = errors.password
                }
            }
        }
    }

    private fun observeState() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.state.collect { state ->
                    when (state) {
                        is SignInState.Idle -> setSubmitting(false)

                        is SignInState.Submitting -> setSubmitting(true)

                        is SignInState.Success -> {
                            setSubmitting(false)
                            findNavController().navigate(R.id.action_signIn_to_home)
                        }

                        is SignInState.Failure -> {
                            setSubmitting(false)
                            Snackbar.make(binding.root, state.message, Snackbar.LENGTH_LONG)
                                .setAction(R.string.retry) { submit() }
                                .show()
                            viewModel.onFailureShown()
                        }
                    }
                }
            }
        }
    }

    private fun setSubmitting(submitting: Boolean) = with(binding) {
        signInButton.isEnabled = !submitting
        signInButton.setText(if (submitting) R.string.signing_in else R.string.sign_in)
        signInProgress.isVisible = submitting
        // Nothing good comes of letting them wander off to sign-up mid-request.
        goToSignUpButton.isEnabled = !submitting
        emailInput.isEnabled = !submitting
        passwordInput.isEnabled = !submitting
    }

    override fun onDestroyView() {
        _binding = null
        super.onDestroyView()
    }
}
