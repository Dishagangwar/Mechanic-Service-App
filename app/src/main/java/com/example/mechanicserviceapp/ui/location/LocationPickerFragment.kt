package com.example.mechanicserviceapp.ui.location

import android.Manifest
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.os.bundleOf
import androidx.core.view.isVisible
import androidx.fragment.app.Fragment
import androidx.fragment.app.setFragmentResult
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.navigation.fragment.findNavController
import androidx.recyclerview.widget.LinearLayoutManager
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.FragmentLocationPickerBinding
import com.example.mechanicserviceapp.domain.model.SearchLocation
import com.google.android.material.snackbar.Snackbar
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch

/**
 * Where the user says where to look.
 *
 * Three routes in: the device's own position, a typed place name, or the location
 * they used last. The typed route is what keeps the app usable when location is
 * denied or unavailable, and it is also how somebody plans ahead for a town they
 * are not in yet.
 */
@AndroidEntryPoint
class LocationPickerFragment : Fragment() {

    private var _binding: FragmentLocationPickerBinding? = null
    private val binding get() = _binding!!

    private val viewModel: LocationPickerViewModel by viewModels()

    private val adapter by lazy { LocationAdapter(onClick = viewModel::choose) }

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { grants ->
        if (grants.values.any { it }) {
            viewModel.useDeviceLocation()
        } else {
            // Denial is a normal answer, not an error state: the search box is still
            // right there, so say so instead of nagging.
            Snackbar.make(
                binding.root,
                R.string.location_permission_rationale,
                Snackbar.LENGTH_LONG
            ).show()
        }
    }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentLocationPickerBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        binding.toolbar.setNavigationOnClickListener { findNavController().navigateUp() }

        binding.resultsRecyclerView.layoutManager = LinearLayoutManager(requireContext())
        binding.resultsRecyclerView.adapter = adapter

        binding.useDeviceLocationButton.setOnClickListener { requestDeviceLocation() }

        binding.searchButton.setOnClickListener { runSearch() }
        binding.searchInput.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_SEARCH) { runSearch(); true } else false
        }

        observeState()
    }

    private fun runSearch() {
        viewModel.search(binding.searchInput.text?.toString().orEmpty())
    }

    private fun requestDeviceLocation() {
        // Coarse is all this app asks for; fine is included only because some devices
        // grant it instead and refusing that would be perverse.
        permissionLauncher.launch(
            arrayOf(
                Manifest.permission.ACCESS_COARSE_LOCATION,
                Manifest.permission.ACCESS_FINE_LOCATION
            )
        )
    }

    private fun observeState() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.state.collect(::render)
            }
        }
    }

    private fun render(state: LocationPickerUiState) = with(binding) {
        state.chosen?.let { deliver(it); return@with }

        if (state.needsPermission) {
            viewModel.onPermissionPromptShown()
            requestDeviceLocation()
        }

        locatingProgress.isVisible = state.isLocating
        useDeviceLocationButton.isEnabled = !state.isLocating
        searchProgress.isVisible = state.isSearching

        adapter.submitList(state.results)
        resultsLabel.isVisible = state.results.isNotEmpty()

        val lastUsed = state.lastUsed
        lastUsedCard.isVisible = lastUsed != null && state.results.isEmpty()
        if (lastUsed != null) {
            lastUsedText.text = lastUsed.label
            lastUsedCard.setOnClickListener { viewModel.choose(lastUsed) }
        }

        state.error?.let {
            Snackbar.make(root, it, Snackbar.LENGTH_LONG).show()
            viewModel.onErrorShown()
        }
    }

    /** Hands the choice back to whoever opened the picker, then closes. */
    private fun deliver(location: SearchLocation) {
        setFragmentResult(
            RESULT_KEY,
            bundleOf(
                ARG_LAT to location.latitude,
                ARG_LNG to location.longitude,
                ARG_LABEL to location.label
            )
        )
        findNavController().navigateUp()
    }

    override fun onDestroyView() {
        binding.resultsRecyclerView.adapter = null
        _binding = null
        super.onDestroyView()
    }

    companion object {
        const val RESULT_KEY = "location_picker_result"
        const val ARG_LAT = "lat"
        const val ARG_LNG = "lng"
        const val ARG_LABEL = "label"
    }
}
