package com.example.mechanicserviceapp.ui.home

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.core.os.bundleOf
import androidx.fragment.app.Fragment
import androidx.fragment.app.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.navigation.fragment.findNavController
import androidx.recyclerview.widget.LinearLayoutManager
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.FragmentHomeBinding
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.example.mechanicserviceapp.ui.detail.MechanicDetailViewModel
import com.example.mechanicserviceapp.util.Resource
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.snackbar.Snackbar
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch

@AndroidEntryPoint
class HomeFragment : Fragment() {

    private var _binding: FragmentHomeBinding? = null
    private val binding get() = _binding!!

    private val viewModel: HomeViewModel by viewModels()

    private val adapter by lazy {
        MechanicAdapter(onClick = ::openDetail)
    }

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
        binding.stateView.stateRetryButton.setOnClickListener { viewModel.loadMechanics() }

        setUpToolbar()
        observeState()
        observeSignOut()
    }

    private fun setUpToolbar() {
        viewModel.signedInName?.let { name ->
            binding.toolbar.subtitle = getString(R.string.greeting_format, name)
        }

        binding.toolbar.setOnMenuItemClickListener { item ->
            when (item.itemId) {
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
                            Snackbar.make(binding.root, state.message, Snackbar.LENGTH_LONG)
                                .show()
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

    private fun render(state: Resource<List<Mechanic>>) = with(binding) {
        when (state) {
            is Resource.Loading -> {
                // A pull-to-refresh already shows its own spinner; don't stack two.
                progressBar.visibility =
                    if (swipeRefresh.isRefreshing) View.GONE else View.VISIBLE
                stateView.stateContainer.visibility = View.GONE
                countText.visibility = View.GONE
            }

            is Resource.Success -> {
                progressBar.visibility = View.GONE
                swipeRefresh.isRefreshing = false
                adapter.submitList(state.data)

                if (state.data.isEmpty()) {
                    countText.visibility = View.GONE
                    showState(
                        iconRes = R.drawable.ic_error,
                        title = getString(R.string.empty_title),
                        message = getString(R.string.empty_message),
                        showRetry = true
                    )
                } else {
                    stateView.stateContainer.visibility = View.GONE
                    countText.visibility = View.VISIBLE
                    countText.text = getString(R.string.mechanics_count, state.data.size)
                }
            }

            is Resource.Error -> {
                progressBar.visibility = View.GONE
                swipeRefresh.isRefreshing = false
                countText.visibility = View.GONE
                showState(
                    iconRes = R.drawable.ic_error,
                    title = getString(R.string.error_title),
                    message = state.message,
                    showRetry = true
                )
            }
        }
    }

    private fun showState(
        iconRes: Int,
        title: String,
        message: String,
        showRetry: Boolean
    ) = with(binding.stateView) {
        stateContainer.visibility = View.VISIBLE
        stateIcon.setImageResource(iconRes)
        stateTitle.text = title
        stateMessage.text = message
        stateRetryButton.visibility = if (showRetry) View.VISIBLE else View.GONE
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
}
