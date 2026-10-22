package com.example.mechanicserviceapp.ui.request

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.core.widget.doOnTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.navigation.fragment.findNavController
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.DialogConfirmationBinding
import com.example.mechanicserviceapp.databinding.FragmentRequestServiceBinding
import com.example.mechanicserviceapp.domain.model.ServiceRequestResult
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.snackbar.Snackbar
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch

@AndroidEntryPoint
class RequestServiceFragment : Fragment() {

    private var _binding: FragmentRequestServiceBinding? = null
    private val binding get() = _binding!!

    private val viewModel: RequestServiceViewModel by viewModels()

    private val mechanicName: String
        get() = arguments?.getString(RequestServiceViewModel.ARG_MECHANIC_NAME).orEmpty()

    private val services: List<String>
        get() = arguments
            ?.getStringArray(RequestServiceViewModel.ARG_SERVICES)
            ?.toList()
            .orEmpty()

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentRequestServiceBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        binding.toolbar.setNavigationOnClickListener { findNavController().navigateUp() }
        binding.bookingForText.text = getString(R.string.request_for_format, mechanicName)
        binding.serviceInput.setSimpleItems(services.toTypedArray())

        wireErrorClearing()

        binding.submitButton.setOnClickListener {
            viewModel.submit(
                name = binding.nameInput.text?.toString().orEmpty(),
                phone = binding.phoneInput.text?.toString().orEmpty(),
                vehicleNumber = binding.vehicleInput.text?.toString().orEmpty(),
                service = binding.serviceInput.text?.toString().orEmpty(),
                problem = binding.problemInput.text?.toString().orEmpty()
            )
        }

        observeErrors()
        observeSubmission()
    }

    /** Wipe a field's error as soon as the user starts correcting it. */
    private fun wireErrorClearing() {
        binding.nameInput.doOnTextChanged { _, _, _, _ ->
            viewModel.clearError(Field.NAME)
        }
        binding.phoneInput.doOnTextChanged { _, _, _, _ ->
            viewModel.clearError(Field.PHONE)
        }
        binding.vehicleInput.doOnTextChanged { _, _, _, _ ->
            viewModel.clearError(Field.VEHICLE)
        }
        binding.serviceInput.doOnTextChanged { _, _, _, _ ->
            viewModel.clearError(Field.SERVICE)
        }
        binding.problemInput.doOnTextChanged { _, _, _, _ ->
            viewModel.clearError(Field.PROBLEM)
        }
    }

    private fun observeErrors() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.errors.collect { errors ->
                    binding.nameLayout.error = errors.name
                    binding.phoneLayout.error = errors.phone
                    binding.vehicleLayout.error = errors.vehicleNumber
                    binding.serviceLayout.error = errors.service
                    binding.problemLayout.error = errors.problem
                }
            }
        }
    }

    private fun observeSubmission() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.submission.collect { state ->
                    when (state) {
                        is SubmissionState.Idle -> setSubmitting(false)

                        is SubmissionState.Submitting -> setSubmitting(true)

                        is SubmissionState.Success -> {
                            setSubmitting(false)
                            showConfirmation(state.result)
                        }

                        is SubmissionState.Failure -> {
                            setSubmitting(false)
                            Snackbar.make(
                                binding.root,
                                state.message,
                                Snackbar.LENGTH_LONG
                            ).setAction(R.string.retry) {
                                binding.submitButton.performClick()
                            }.show()
                            viewModel.onFailureShown()
                        }
                    }
                }
            }
        }
    }

    private fun setSubmitting(submitting: Boolean) = with(binding) {
        submitButton.isEnabled = !submitting
        submitButton.setText(
            if (submitting) R.string.submitting else R.string.submit_request
        )
    }

    private fun showConfirmation(result: ServiceRequestResult) {
        val dialogBinding = DialogConfirmationBinding.inflate(layoutInflater)
        dialogBinding.confirmationMessage.text = result.message
        dialogBinding.confirmationEta.text =
            getString(R.string.confirmation_eta, result.etaMinutes)
        dialogBinding.confirmationRequestId.text =
            getString(R.string.confirmation_request_id, result.requestId)

        MaterialAlertDialogBuilder(requireContext())
            .setView(dialogBinding.root)
            .setCancelable(false)
            .setPositiveButton(R.string.done) { dialog, _ ->
                dialog.dismiss()
                // Back to the list — the booking is done, the form is spent.
                findNavController().popBackStack(R.id.homeFragment, false)
            }
            .show()
    }

    override fun onDestroyView() {
        _binding = null
        super.onDestroyView()
    }
}
