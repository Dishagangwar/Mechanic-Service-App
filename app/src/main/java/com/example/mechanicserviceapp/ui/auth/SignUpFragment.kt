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
import com.example.mechanicserviceapp.databinding.FragmentSignUpBinding
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.snackbar.Snackbar
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch

@AndroidEntryPoint
class SignUpFragment : Fragment() {

    private var _binding: FragmentSignUpBinding? = null
    private val binding get() = _binding!!

    private val viewModel: SignUpViewModel by viewModels()

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentSignUpBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        binding.toolbar.setNavigationOnClickListener { findNavController().navigateUp() }
        binding.signUpButton.setOnClickListener { submit() }
        binding.goToSignInButton.setOnClickListener { findNavController().navigateUp() }

        wireErrorClearing()
        observeErrors()
        observeState()
    }

    /** Wipe a field's error as soon as the user starts correcting it. */
    private fun wireErrorClearing() {
        binding.nameInput.doOnTextChanged { _, _, _, _ ->
            viewModel.clearError(SignUpField.NAME)
        }
        binding.emailInput.doOnTextChanged { _, _, _, _ ->
            viewModel.clearError(SignUpField.EMAIL)
        }
        binding.phoneInput.doOnTextChanged { _, _, _, _ ->
            viewModel.clearError(SignUpField.PHONE)
        }
        binding.passwordInput.doOnTextChanged { _, _, _, _ ->
            viewModel.clearError(SignUpField.PASSWORD)
        }
        binding.confirmPasswordInput.doOnTextChanged { _, _, _, _ ->
            viewModel.clearError(SignUpField.CONFIRM_PASSWORD)
        }
    }

    private fun submit() {
        viewModel.signUp(
            fullName = binding.nameInput.text?.toString().orEmpty(),
            email = binding.emailInput.text?.toString().orEmpty(),
            phone = binding.phoneInput.text?.toString().orEmpty(),
            password = binding.passwordInput.text?.toString().orEmpty(),
            confirmPassword = binding.confirmPasswordInput.text?.toString().orEmpty()
        )
    }

    private fun observeErrors() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.errors.collect { errors ->
                    binding.nameLayout.error = errors.fullName
                    binding.emailLayout.error = errors.email
                    binding.phoneLayout.error = errors.phone
                    binding.passwordLayout.error = errors.password
                    binding.confirmPasswordLayout.error = errors.confirmPassword
                }
            }
        }
    }

    private fun observeState() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.state.collect { state ->
                    when (state) {
                        is SignUpState.Idle -> setSubmitting(false)

                        is SignUpState.Submitting -> setSubmitting(true)

                        is SignUpState.Success -> {
                            setSubmitting(false)
                            findNavController().navigate(R.id.action_signUp_to_home)
                        }

                        is SignUpState.ConfirmationRequired -> {
                            setSubmitting(false)
                            showConfirmEmailDialog(state.email)
                        }

                        is SignUpState.Failure -> {
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

    /**
     * The account exists but has no session yet. Send them back to sign-in rather than
     * leaving them on a form they have already submitted.
     */
    private fun showConfirmEmailDialog(email: String) {
        MaterialAlertDialogBuilder(requireContext())
            .setTitle(R.string.verify_email_title)
            .setMessage(getString(R.string.verify_email_message, email))
            .setCancelable(false)
            .setPositiveButton(R.string.got_it) { dialog, _ ->
                dialog.dismiss()
                viewModel.onFailureShown()
                findNavController().navigateUp()
            }
            .show()
    }

    private fun setSubmitting(submitting: Boolean) = with(binding) {
        signUpButton.isEnabled = !submitting
        signUpButton.setText(if (submitting) R.string.signing_up else R.string.sign_up)
        signUpProgress.isVisible = submitting
        goToSignInButton.isEnabled = !submitting
        nameInput.isEnabled = !submitting
        emailInput.isEnabled = !submitting
        phoneInput.isEnabled = !submitting
        passwordInput.isEnabled = !submitting
        confirmPasswordInput.isEnabled = !submitting
    }

    override fun onDestroyView() {
        _binding = null
        super.onDestroyView()
    }
}
