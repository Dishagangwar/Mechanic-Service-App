package com.example.mechanicserviceapp.ui.home

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import androidx.core.net.toUri
import androidx.core.os.bundleOf
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import androidx.fragment.app.Fragment
import androidx.fragment.app.setFragmentResultListener
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.navigation.fragment.findNavController
import androidx.recyclerview.widget.LinearLayoutManager
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.FragmentHomeBinding
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.domain.model.MechanicCategory
import com.example.mechanicserviceapp.domain.model.SearchLocation
import com.example.mechanicserviceapp.domain.model.SearchRadius
import com.example.mechanicserviceapp.ui.detail.MechanicDetailViewModel
import com.example.mechanicserviceapp.ui.location.LocationPickerFragment
import com.example.mechanicserviceapp.util.Attribution
import com.example.mechanicserviceapp.util.Diag
import com.example.mechanicserviceapp.util.Resource
import com.google.android.material.chip.Chip
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.snackbar.Snackbar
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@AndroidEntryPoint
class HomeFragment : Fragment() {

    private var _binding: FragmentHomeBinding? = null
    private val binding get() = _binding!!

    private val viewModel: HomeViewModel by viewModels()

    private val adapter by lazy { MechanicAdapter(onClick = ::openDetail) }

    /** Debounces the search box so each keystroke is not a round trip. */
    private var searchJob: Job? = null

    /** Suppresses the chip listeners while they are being set up programmatically. */
    private var bindingChips = false

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentHomeBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        binding.mechanicsRecyclerView.layoutManager = LinearLayoutManager(requireContext())
        binding.mechanicsRecyclerView.adapter = adapter

        binding.swipeRefresh.setOnRefreshListener { viewModel.refresh() }
        binding.stateView.stateRetryButton.setOnClickListener { onRetry() }

        binding.locationBar.setOnClickListener { openLocationPicker() }
        binding.changeLocationButton.setOnClickListener { openLocationPicker() }

        setUpSearch()
        setUpRadiusChips()
        setUpCategoryChips()
        setUpToolbar()
        listenForLocationResult()
        observeState()
        observeSignOut()
    }

    /** The picker hands its choice back here rather than writing to a shared singleton. */
    private fun listenForLocationResult() {
        setFragmentResultListener(LocationPickerFragment.RESULT_KEY) { _, bundle ->
            val latitude = bundle.getDouble(LocationPickerFragment.ARG_LAT, Double.NaN)
            val longitude = bundle.getDouble(LocationPickerFragment.ARG_LNG, Double.NaN)
            val label = bundle.getString(LocationPickerFragment.ARG_LABEL).orEmpty()
            Diag.log("picker result received: '$label' $latitude,$longitude")
            if (latitude.isNaN() || longitude.isNaN() || label.isBlank()) {
                Diag.warn("picker result DISCARDED (nan or blank label)")
                return@setFragmentResultListener
            }

            viewModel.onLocationChosen(
                SearchLocation(latitude, longitude, label, SearchLocation.Origin.SEARCHED)
            )
        }
    }

    private fun openLocationPicker() {
        findNavController().navigate(R.id.action_home_to_locationPicker)
    }

    private fun setUpSearch() {
        binding.searchInput.doAfterTextChanged { text ->
            searchJob?.cancel()
            searchJob = viewLifecycleOwner.lifecycleScope.launch {
                delay(SEARCH_DEBOUNCE_MS)
                viewModel.setQuery(text?.toString().orEmpty())
            }
        }
        binding.searchInput.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_SEARCH) {
                searchJob?.cancel()
                viewModel.setQuery(binding.searchInput.text?.toString().orEmpty())
                true
            } else {
                false
            }
        }
    }

    private fun setUpRadiusChips() {
        bindingChips = true
        binding.radiusChipGroup.removeAllViews()
        SearchRadius.entries.forEach { radius ->
            binding.radiusChipGroup.addView(
                newChip(
                    label = getString(R.string.radius_label, radius.label),
                    checked = radius == viewModel.state.value.radius,
                    tag = radius
                )
            )
        }
        binding.radiusChipGroup.setOnCheckedStateChangeListener { group, ids ->
            if (bindingChips) return@setOnCheckedStateChangeListener
            val radius = ids.firstOrNull()?.let { group.findViewById<Chip>(it)?.tag as? SearchRadius }
            radius?.let(viewModel::setRadius)
        }
        bindingChips = false
    }

    private fun setUpCategoryChips() {
        bindingChips = true
        binding.categoryChipGroup.removeAllViews()
        // A null tag is the "All" chip; everything else carries its category.
        binding.categoryChipGroup.addView(
            newChip(getString(R.string.filter_all), checked = true, tag = null)
        )
        MechanicCategory.entries.forEach { category ->
            binding.categoryChipGroup.addView(
                newChip(category.label, checked = false, tag = category)
            )
        }
        binding.categoryChipGroup.setOnCheckedStateChangeListener { group, ids ->
            if (bindingChips) return@setOnCheckedStateChangeListener
            val chip = ids.firstOrNull()?.let { group.findViewById<Chip>(it) }
            viewModel.setCategory(chip?.tag as? MechanicCategory)
        }
        bindingChips = false
    }

    private fun newChip(label: String, checked: Boolean, tag: Any?): Chip =
        (layoutInflater.inflate(R.layout.item_filter_chip, binding.radiusChipGroup, false) as Chip)
            .apply {
                text = label
                id = View.generateViewId()
                isChecked = checked
                this.tag = tag
            }

    private fun setUpToolbar() {
        viewModel.signedInName?.let { name ->
            binding.toolbar.subtitle = getString(R.string.greeting_format, name)
        }

        binding.toolbar.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                R.id.action_my_requests -> {
                    findNavController().navigate(R.id.action_home_to_myRequests)
                    true
                }

                R.id.action_garage -> {
                    findNavController().navigate(R.id.action_home_to_garage)
                    true
                }

                R.id.action_sign_out -> {
                    confirmSignOut()
                    true
                }

                else -> false
            }
        }
    }

    private fun confirmSignOut() {
        MaterialAlertDialogBuilder(requireContext())
            .setTitle(R.string.sign_out_title)
            .setMessage(R.string.sign_out_message)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.sign_out) { _, _ -> viewModel.signOut() }
            .show()
    }

    private fun observeSignOut() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.signOutState.collect { state ->
                    when (state) {
                        is SignOutState.Idle, is SignOutState.InProgress -> Unit

                        is SignOutState.Done ->
                            findNavController().navigate(R.id.action_home_to_signIn)

                        is SignOutState.Failed -> {
                            Snackbar.make(binding.root, state.message, Snackbar.LENGTH_LONG).show()
                            viewModel.onSignOutFailureShown()
                        }
                    }
                }
            }
        }
    }

    private fun observeState() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.state.collect(::render)
            }
        }
    }

    private fun onRetry() {
        if (viewModel.state.value.location == null) openLocationPicker() else viewModel.refresh()
    }

    private fun render(state: HomeUiState) = with(binding) {
        locationText.text = state.location?.label ?: getString(R.string.location_none)

        // Filtering and searching make no sense before there is somewhere to search.
        val hasLocation = state.location != null
        searchLayout.isVisible = hasLocation
        radiusChipGroup.isVisible = hasLocation
        categoryChipGroup.isVisible = hasLocation

        renderCoverage(state)

        if (!hasLocation) {
            progressBar.isVisible = false
            swipeRefresh.isRefreshing = false
            countText.isVisible = false
            showState(
                iconRes = R.drawable.ic_location,
                title = getString(R.string.location_none),
                message = getString(R.string.location_permission_rationale),
                retryLabel = getString(R.string.location_change)
            )
            return@with
        }

        when (val mechanics = state.mechanics) {
            is Resource.Loading -> {
                // Pull-to-refresh shows its own spinner; don't stack two.
                progressBar.isVisible = !swipeRefresh.isRefreshing
                stateView.stateContainer.isVisible = false
                countText.isVisible = false
            }

            is Resource.Success -> {
                progressBar.isVisible = false
                swipeRefresh.isRefreshing = false
                adapter.submitList(mechanics.data)

                if (mechanics.data.isEmpty()) {
                    countText.isVisible = false
                    renderEmpty(state)
                } else {
                    stateView.stateContainer.isVisible = false
                    countText.isVisible = true
                    countText.text = getString(R.string.mechanics_count, mechanics.data.size)
                }
                renderAttribution(mechanics.data)
            }

            is Resource.Error -> {
                progressBar.isVisible = false
                swipeRefresh.isRefreshing = false
                countText.isVisible = false
                showState(
                    iconRes = R.drawable.ic_error,
                    title = getString(R.string.error_title),
                    message = mechanics.message,
                    retryLabel = getString(R.string.retry)
                )
            }
        }
    }

    /**
     * An empty list has three different causes and three different fixes, so it
     * gets three different screens. Offering "Retry" for a region that was
     * checked and genuinely has no garages just invites the user to wait for the
     * same answer.
     */
    private fun renderEmpty(state: HomeUiState) {
        val where = state.location?.label.orEmpty()
        when {
            state.hasFilters -> showState(
                iconRes = R.drawable.ic_error,
                title = getString(R.string.empty_title),
                message = getString(R.string.empty_filtered_message, where),
                retryLabel = getString(R.string.filter_clear),
                onRetry = ::clearFilters
            )

            viewModel.canWiden -> showState(
                iconRes = R.drawable.ic_location,
                title = getString(R.string.empty_title),
                message = getString(R.string.empty_message, where),
                retryLabel = getString(R.string.empty_widen, nextRadiusLabel()),
                onRetry = { viewModel.widenRadius() }
            )

            // Already at the widest radius: nothing left to widen to, so say so
            // plainly instead of dangling a button that cannot help.
            else -> showState(
                iconRes = R.drawable.ic_error,
                title = getString(R.string.empty_title),
                message = getString(R.string.empty_widest_message, where),
                retryLabel = getString(R.string.location_change),
                onRetry = ::openLocationPicker
            )
        }
    }

    private fun nextRadiusLabel(): String =
        SearchRadius.entries
            .firstOrNull { it.km > viewModel.state.value.radius.km }
            ?.label.orEmpty()

    /**
     * Credit whoever actually supplied these rows. Required by all three
     * providers, and they do not all want the same wording, so it follows the
     * data rather than sitting hardcoded in the layout.
     */
    private fun renderAttribution(mechanics: List<Mechanic>) {
        val credit = Attribution.forMechanics(mechanics)
        binding.attributionText.isVisible = credit != null
        binding.attributionText.text = credit

        val sources = mechanics.map { it.source }.distinct()
        if (Attribution.linksToOdbl(sources)) {
            binding.attributionText.setOnClickListener {
                runCatching {
                    startActivity(Intent(Intent.ACTION_VIEW, Attribution.ODBL_URL.toUri()))
                }
            }
        } else {
            binding.attributionText.setOnClickListener(null)
            binding.attributionText.isClickable = false
        }
    }

    private fun clearFilters() {
        bindingChips = true
        binding.searchInput.setText("")
        (binding.categoryChipGroup.getChildAt(0) as? Chip)?.isChecked = true
        bindingChips = false
        viewModel.clearFilters()
    }

    /**
     * Surfaces a region import as a transient note. Importing is a side effect the
     * user did not ask for, so it gets a snackbar and never blocks the list.
     */
    private fun renderCoverage(state: HomeUiState) {
        when (val coverage = state.coverage) {
            is CoverageState.Imported -> {
                Snackbar.make(
                    binding.root,
                    getString(R.string.coverage_imported, coverage.count),
                    Snackbar.LENGTH_SHORT
                ).show()
                viewModel.onCoverageNoticeShown()
            }

            is CoverageState.Failed -> {
                // Non-fatal: whatever is already cached stays on screen.
                Snackbar.make(binding.root, R.string.coverage_failed, Snackbar.LENGTH_SHORT).show()
                viewModel.onCoverageNoticeShown()
            }

            // Handled by the empty state, which can actually offer a next step.
            // A snackbar here would just repeat it.
            is CoverageState.EmptyRegion -> viewModel.onCoverageNoticeShown()

            is CoverageState.Checking, is CoverageState.Idle -> Unit
        }
    }

    private fun showState(
        iconRes: Int,
        title: String,
        message: String,
        retryLabel: String,
        onRetry: (() -> Unit)? = null
    ) = with(binding.stateView) {
        stateContainer.isVisible = true
        stateIcon.setImageResource(iconRes)
        stateTitle.text = title
        stateMessage.text = message
        stateRetryButton.isVisible = true
        stateRetryButton.text = retryLabel
        stateRetryButton.setOnClickListener { (onRetry ?: ::onRetry).invoke() }
    }

    private fun openDetail(mechanic: Mechanic) {
        findNavController().navigate(
            R.id.action_home_to_detail,
            bundleOf(MechanicDetailViewModel.ARG_MECHANIC_ID to mechanic.id)
        )
    }

    override fun onDestroyView() {
        // The RecyclerView outlives the binding otherwise and leaks the view tree.
        binding.mechanicsRecyclerView.adapter = null
        _binding = null
        super.onDestroyView()
    }

    private companion object {
        const val SEARCH_DEBOUNCE_MS = 350L
    }
}
