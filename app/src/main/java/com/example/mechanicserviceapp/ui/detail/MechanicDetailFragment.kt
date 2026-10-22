package com.example.mechanicserviceapp.ui.detail

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.core.os.bundleOf
import androidx.core.view.isVisible
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.navigation.fragment.findNavController
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.FragmentMechanicDetailBinding
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.ui.request.RequestServiceViewModel
import com.example.mechanicserviceapp.util.Resource
import com.google.android.material.chip.Chip
import com.google.android.material.snackbar.Snackbar
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch

@AndroidEntryPoint
class MechanicDetailFragment : Fragment() {

    private var _binding: FragmentMechanicDetailBinding? = null
    private val binding get() = _binding!!

    private val viewModel: MechanicDetailViewModel by viewModels()

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentMechanicDetailBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        binding.toolbar.setNavigationOnClickListener { findNavController().navigateUp() }
        binding.stateView.stateRetryButton.setOnClickListener { viewModel.load() }

        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.state.collect(::render)
            }
        }
    }

    private fun render(state: Resource<Mechanic>) = with(binding) {
        when (state) {
            is Resource.Loading -> {
                progressBar.visibility = View.VISIBLE
                contentScroll.visibility = View.GONE
                requestServiceButton.visibility = View.GONE
                stateView.stateContainer.visibility = View.GONE
            }

            is Resource.Success -> {
                progressBar.visibility = View.GONE
                stateView.stateContainer.visibility = View.GONE
                contentScroll.visibility = View.VISIBLE
                requestServiceButton.visibility = View.VISIBLE
                bind(state.data)
            }

            is Resource.Error -> {
                progressBar.visibility = View.GONE
                contentScroll.visibility = View.GONE
                requestServiceButton.visibility = View.GONE
                stateView.stateContainer.visibility = View.VISIBLE
                stateView.stateTitle.text = getString(R.string.error_title)
                stateView.stateMessage.text = state.message
            }
        }
    }

    /**
     * Most of this is about saying "we don't know" properly.
     *
     * These are real listings and the majority are missing a phone number, hours or
     * both. Where a field is absent the row says so in plain words and the control it
     * would have driven is disabled — a call button that dials nothing is worse than
     * no call button.
     */
    private fun bind(mechanic: Mechanic) = with(binding) {
        val context = requireContext()

        toolbar.title = mechanic.displayName
        nameText.text = mechanic.displayName
        secondaryNameText.isVisible = mechanic.secondaryName != null
        secondaryNameText.text = mechanic.secondaryName

        val rating = mechanic.rating
        ratingPill.isVisible = rating != null
        noRatingText.isVisible = rating == null
        reviewCountText.isVisible = rating != null
        if (rating != null) {
            ratingText.text = getString(R.string.rating_format, rating)
            reviewCountText.text = if (mechanic.reviewCount == 1) {
                getString(R.string.review_count_one)
            } else {
                getString(R.string.review_count_format, mechanic.reviewCount)
            }
        }

        addressText.text = mechanic.fullAddress ?: getString(R.string.address_not_listed)

        // Prefer parsed hours when we have them, fall back to the provider's raw
        // string, and otherwise admit we don't know.
        hoursText.text = mechanic.openingHoursRaw ?: getString(R.string.hours_not_listed)

        phoneText.text = mechanic.phone ?: getString(R.string.phone_not_listed)
        callButton.isVisible = mechanic.hasPhone

        bindStatus(mechanic)

        servicesChipGroup.removeAllViews()
        val inflater = LayoutInflater.from(context)
        mechanic.services.forEach { service ->
            val chip = inflater.inflate(
                R.layout.item_service_chip, servicesChipGroup, false
            ) as Chip
            chip.text = service
            chip.isClickable = false
            servicesChipGroup.addView(chip)
        }
        servicesNoteText.isVisible = mechanic.services.isNotEmpty()
        servicesNoteText.setText(
            if (mechanic.hasDeclaredServices) {
                R.string.services_declared_note
            } else {
                R.string.services_inferred_note
            }
        )

        callButton.setOnClickListener { mechanic.phone?.let(::dial) }

        requestServiceButton.setOnClickListener {
            findNavController().navigate(
                R.id.action_detail_to_request,
                bundleOf(
                    RequestServiceViewModel.ARG_MECHANIC_ID to mechanic.id,
                    RequestServiceViewModel.ARG_MECHANIC_NAME to mechanic.displayName,
                    RequestServiceViewModel.ARG_SERVICES to mechanic.services.toTypedArray()
                )
            )
        }
    }

    /**
     * Three states. A null [Mechanic.isOpen] means nobody recorded this garage's
     * hours, which is not the same as being closed.
     */
    private fun bindStatus(mechanic: Mechanic) = with(binding) {
        val context = requireContext()
        when (mechanic.isOpen) {
            true -> {
                statusText.setText(R.string.status_open)
                statusText.setBackgroundResource(R.drawable.bg_status_open)
                statusText.setTextColor(context.getColor(R.color.status_open))
            }

            false -> {
                statusText.setText(R.string.status_closed)
                statusText.setBackgroundResource(R.drawable.bg_status_closed)
                statusText.setTextColor(context.getColor(R.color.status_closed))
            }

            null -> {
                statusText.setText(R.string.status_hours_unknown)
                statusText.setBackgroundResource(R.drawable.bg_status_unknown)
                statusText.setTextColor(context.getColor(R.color.status_unknown))
            }
        }
    }

    /**
     * ACTION_DIAL only opens the dialer with the number filled in — it never places the
     * call, so no CALL_PHONE permission is involved.
     */
    private fun dial(phone: String) {
        if (phone.isBlank()) return
        try {
            startActivity(Intent(Intent.ACTION_DIAL, "tel:$phone".toUri()))
        } catch (_: ActivityNotFoundException) {
            Snackbar.make(binding.root, R.string.no_dialer, Snackbar.LENGTH_SHORT).show()
        }
    }

    private fun String.toUri(): Uri = Uri.parse(this)

    override fun onDestroyView() {
        _binding = null
        super.onDestroyView()
    }
}
