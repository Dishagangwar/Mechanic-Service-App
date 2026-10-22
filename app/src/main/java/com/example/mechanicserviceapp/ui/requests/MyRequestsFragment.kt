package com.example.mechanicserviceapp.ui.requests

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
import androidx.recyclerview.widget.LinearLayoutManager
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.DialogReviewBinding
import com.example.mechanicserviceapp.databinding.FragmentMyRequestsBinding
import com.example.mechanicserviceapp.domain.model.CustomerRequest
import com.example.mechanicserviceapp.util.Resource
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.snackbar.Snackbar
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch

/**
 * The screen that turns a booking into something with a life after the confirmation
 * dialog. Before this existed, a submitted request was unrecoverable — it had no
 * status, no history, and no way to be rated.
 */
@AndroidEntryPoint
class MyRequestsFragment : Fragment() {

    private var _binding: FragmentMyRequestsBinding? = null
    private val binding get() = _binding!!

    private val viewModel: MyRequestsViewModel by viewModels()

    private val adapter by lazy {
        RequestAdapter(onCancel = ::confirmCancel, onReview = ::openReviewDialog)
    }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentMyRequestsBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        binding.toolbar.setNavigationOnClickListener { findNavController().navigateUp() }

        binding.requestsRecyclerView.layoutManager = LinearLayoutManager(requireContext())
        binding.requestsRecyclerView.adapter = adapter

        binding.swipeRefresh.setOnRefreshListener { viewModel.load() }
        binding.stateView.stateRetryButton.setOnClickListener { viewModel.load() }

        observeState()
    }

    private fun observeState() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.state.collect(::render)
            }
        }
    }

    private fun render(state: MyRequestsUiState) = with(binding) {
        renderAction(state)

        when (val requests = state.requests) {
            is Resource.Loading -> {
                progressBar.isVisible = !swipeRefresh.isRefreshing
                stateView.stateContainer.isVisible = false
            }

            is Resource.Success -> {
                progressBar.isVisible = false
                swipeRefresh.isRefreshing = false
                adapter.submitList(requests.data)

                if (requests.data.isEmpty()) {
                    showState(
                        title = getString(R.string.requests_empty_title),
                        message = getString(R.string.requests_empty_message)
                    )
                } else {
                    stateView.stateContainer.isVisible = false
                }
            }

            is Resource.Error -> {
                progressBar.isVisible = false
                swipeRefresh.isRefreshing = false
                showState(
                    title = getString(R.string.error_title),
                    message = requests.message
                )
            }
        }
    }

    private fun renderAction(state: MyRequestsUiState) {
        when (val action = state.action) {
            is RequestAction.Cancelled -> {
                Snackbar.make(binding.root, R.string.request_cancelled, Snackbar.LENGTH_SHORT).show()
                viewModel.onActionShown()
            }

            is RequestAction.Reviewed -> {
                Snackbar.make(binding.root, R.string.review_submitted, Snackbar.LENGTH_SHORT).show()
                viewModel.onActionShown()
            }

            is RequestAction.Failed -> {
                Snackbar.make(binding.root, action.message, Snackbar.LENGTH_LONG).show()
                viewModel.onActionShown()
            }

            is RequestAction.Idle, is RequestAction.Working -> Unit
        }
    }

    private fun confirmCancel(request: CustomerRequest) {
        MaterialAlertDialogBuilder(requireContext())
            .setTitle(R.string.request_cancel_title)
            .setMessage(R.string.request_cancel_message)
            .setNegativeButton(R.string.request_keep, null)
            .setPositiveButton(R.string.request_cancel_confirm) { _, _ ->
                viewModel.cancel(request.id)
            }
            .show()
    }

    private fun openReviewDialog(request: CustomerRequest) {
        val dialogBinding = DialogReviewBinding.inflate(layoutInflater)
        dialogBinding.titleText.text = getString(R.string.review_title, request.mechanicName)

        val dialog = MaterialAlertDialogBuilder(requireContext())
            .setView(dialogBinding.root)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.review_submit, null)
            .create()

        dialog.show()
        // Set the click listener after show() so an invalid rating can keep the dialog
        // open instead of dismissing and losing what they typed.
        dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            val rating = dialogBinding.ratingBar.rating.toInt()
            if (rating < 1) {
                Snackbar.make(dialogBinding.root, R.string.review_pick_rating, Snackbar.LENGTH_SHORT)
                    .show()
                return@setOnClickListener
            }
            viewModel.submitReview(
                request = request,
                rating = rating,
                comment = dialogBinding.commentInput.text?.toString()
            )
            dialog.dismiss()
        }
    }

    private fun showState(title: String, message: String) = with(binding.stateView) {
        stateContainer.isVisible = true
        stateIcon.setImageResource(R.drawable.ic_clock)
        stateTitle.text = title
        stateMessage.text = message
        stateRetryButton.isVisible = true
        stateRetryButton.setText(R.string.retry)
    }

    override fun onDestroyView() {
        binding.requestsRecyclerView.adapter = null
        _binding = null
        super.onDestroyView()
    }
}
