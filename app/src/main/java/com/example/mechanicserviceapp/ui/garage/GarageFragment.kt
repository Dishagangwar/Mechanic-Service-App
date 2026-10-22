package com.example.mechanicserviceapp.ui.garage

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.core.net.toUri
import androidx.core.os.bundleOf
import androidx.core.view.isVisible
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.navigation.fragment.findNavController
import androidx.recyclerview.widget.LinearLayoutManager
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.DialogAcceptRequestBinding
import com.example.mechanicserviceapp.databinding.FragmentGarageBinding
import com.example.mechanicserviceapp.domain.model.GarageRequest
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.ui.detail.MechanicDetailViewModel
import com.example.mechanicserviceapp.ui.home.MechanicAdapter
import com.example.mechanicserviceapp.util.Resource
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.snackbar.Snackbar
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch

/**
 * The garage owner's screen: the listings they have claimed, and the jobs
 * waiting on them.
 *
 * This is what closes the loop. Until it existed a booking could be filed and
 * then never move, because nothing in the app could accept it.
 */
@AndroidEntryPoint
class GarageFragment : Fragment() {

    private var _binding: FragmentGarageBinding? = null
    private val binding get() = _binding!!

    private val viewModel: GarageViewModel by viewModels()

    private val garageAdapter by lazy { MechanicAdapter(onClick = ::openListing) }

    private val requestAdapter by lazy {
        GarageRequestAdapter(
            onAccept = ::promptAccept,
            onReject = ::confirmReject,
            onStart = viewModel::start,
            onComplete = ::confirmComplete,
            onCall = { dial(it.phoneNumber) }
        )
    }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentGarageBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        binding.toolbar.setNavigationOnClickListener { findNavController().navigateUp() }

        binding.garagesRecyclerView.layoutManager = LinearLayoutManager(requireContext())
        binding.garagesRecyclerView.adapter = garageAdapter
        binding.garagesRecyclerView.isNestedScrollingEnabled = false

        binding.requestsRecyclerView.layoutManager = LinearLayoutManager(requireContext())
        binding.requestsRecyclerView.adapter = requestAdapter
        binding.requestsRecyclerView.isNestedScrollingEnabled = false

        binding.swipeRefresh.setOnRefreshListener { viewModel.load() }
        binding.findGarageButton.setOnClickListener { findNavController().navigateUp() }

        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.state.collect(::render)
            }
        }
    }

    private fun render(state: GarageUiState) = with(binding) {
        renderAction(state)

        val garages = (state.garages as? Resource.Success)?.data.orEmpty()
        garageAdapter.submitList(garages)

        val loading = state.garages is Resource.Loading || state.requests is Resource.Loading
        progressBar.isVisible = loading && !swipeRefresh.isRefreshing
        if (!loading) swipeRefresh.isRefreshing = false

        // Nothing claimed yet: explain how to become a garage rather than
        // showing two empty lists.
        val hasGarage = state.hasGarage
        emptyGroup.isVisible = !hasGarage && state.garages is Resource.Success
        garagesLabel.isVisible = hasGarage
        garagesRecyclerView.isVisible = hasGarage
        requestsLabel.isVisible = hasGarage
        requestsRecyclerView.isVisible = hasGarage

        if (!hasGarage) return@with

        val requests = (state.requests as? Resource.Success)?.data.orEmpty()
        requestAdapter.submitList(requests)
        requestsEmptyText.isVisible = requests.isEmpty()
        requestsLabel.text = if (state.openRequests.isEmpty()) {
            getString(R.string.garage_requests_label)
        } else {
            getString(R.string.garage_requests_open_format, state.openRequests.size)
        }

        (state.requests as? Resource.Error)?.let {
            requestsEmptyText.isVisible = true
            requestsEmptyText.text = it.message
        }
    }

    private fun renderAction(state: GarageUiState) {
        when (val action = state.action) {
            is GarageAction.Done -> {
                Snackbar.make(binding.root, action.message, Snackbar.LENGTH_SHORT).show()
                viewModel.onActionShown()
            }

            is GarageAction.Failed -> {
                Snackbar.make(binding.root, action.message, Snackbar.LENGTH_LONG).show()
                viewModel.onActionShown()
            }

            is GarageAction.Idle, is GarageAction.Working -> Unit
        }
    }

    /**
     * Accepting means committing to a time, so the ETA is asked for here rather
     * than defaulted. The customer's app has never been able to invent one.
     */
    private fun promptAccept(request: GarageRequest) {
        val dialogBinding = DialogAcceptRequestBinding.inflate(layoutInflater)
        dialogBinding.titleText.text =
            getString(R.string.garage_accept_title, request.customerName.ifBlank { "this customer" })

        val dialog = MaterialAlertDialogBuilder(requireContext())
            .setView(dialogBinding.root)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.garage_accept_confirm, null)
            .create()

        dialog.show()
        dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            val eta = dialogBinding.etaInput.text?.toString()?.trim()?.toIntOrNull()
            if (eta == null || eta <= 0) {
                dialogBinding.etaLayout.error = getString(R.string.garage_eta_required)
                return@setOnClickListener
            }
            viewModel.accept(request, eta, dialogBinding.noteInput.text?.toString())
            dialog.dismiss()
        }
    }

    private fun confirmReject(request: GarageRequest) {
        MaterialAlertDialogBuilder(requireContext())
            .setTitle(R.string.garage_reject_title)
            .setMessage(R.string.garage_reject_message)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.garage_reject_confirm) { _, _ -> viewModel.reject(request) }
            .show()
    }

    private fun confirmComplete(request: GarageRequest) {
        MaterialAlertDialogBuilder(requireContext())
            .setTitle(R.string.garage_complete_title)
            .setMessage(R.string.garage_complete_message)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.garage_complete_confirm) { _, _ ->
                viewModel.complete(request)
            }
            .show()
    }

    private fun openListing(mechanic: Mechanic) {
        findNavController().navigate(
            R.id.action_garage_to_detail,
            bundleOf(MechanicDetailViewModel.ARG_MECHANIC_ID to mechanic.id)
        )
    }

    private fun dial(phone: String) {
        if (phone.isBlank()) return
        try {
            startActivity(Intent(Intent.ACTION_DIAL, "tel:$phone".toUri()))
        } catch (_: ActivityNotFoundException) {
            Snackbar.make(binding.root, R.string.no_dialer, Snackbar.LENGTH_SHORT).show()
        }
    }

    override fun onDestroyView() {
        binding.garagesRecyclerView.adapter = null
        binding.requestsRecyclerView.adapter = null
        _binding = null
        super.onDestroyView()
    }
}
