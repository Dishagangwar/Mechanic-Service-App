package com.example.mechanicserviceapp.ui.requests

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.core.view.isVisible
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.ItemRequestBinding
import com.example.mechanicserviceapp.domain.model.CustomerRequest
import com.example.mechanicserviceapp.domain.model.RequestStatus

class RequestAdapter(
    private val onCancel: (CustomerRequest) -> Unit,
    private val onReview: (CustomerRequest) -> Unit
) : ListAdapter<CustomerRequest, RequestAdapter.RequestViewHolder>(DIFF) {

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = RequestViewHolder(
        ItemRequestBinding.inflate(LayoutInflater.from(parent.context), parent, false)
    )

    override fun onBindViewHolder(holder: RequestViewHolder, position: Int) {
        holder.bind(getItem(position))
    }

    inner class RequestViewHolder(
        private val binding: ItemRequestBinding
    ) : RecyclerView.ViewHolder(binding.root) {

        fun bind(request: CustomerRequest) = with(binding) {
            val context = root.context

            mechanicNameText.text = request.mechanicName
            serviceText.text = request.serviceName
            vehicleText.text = context.getString(R.string.request_vehicle_format, request.vehicleNumber)
            problemText.text = request.problemDescription

            statusText.text = request.status.label
            statusText.setBackgroundResource(request.status.backgroundRes())
            statusText.setTextColor(context.getColor(request.status.colorRes()))

            // An ETA exists only once a garage has committed to one.
            val eta = request.etaMinutes
            etaText.text = if (eta != null) {
                context.getString(R.string.request_eta_format, eta)
            } else {
                context.getString(R.string.request_eta_pending)
            }
            etaText.isVisible = !request.status.isFinished || eta != null

            noteText.isVisible = !request.mechanicNote.isNullOrBlank()
            noteText.text = request.mechanicNote

            cancelButton.isVisible = request.status.isCancellable
            cancelButton.setOnClickListener { onCancel(request) }

            reviewButton.isVisible = request.canReview
            reviewButton.setOnClickListener { onReview(request) }

            myRatingText.isVisible = request.hasReview
            request.myRating?.let {
                myRatingText.text = context.getString(R.string.review_yours_format, it)
            }
        }
    }

    private companion object {
        fun RequestStatus.backgroundRes(): Int = when (this) {
            RequestStatus.COMPLETED, RequestStatus.ACCEPTED, RequestStatus.IN_PROGRESS ->
                R.drawable.bg_status_open

            RequestStatus.CANCELLED, RequestStatus.REJECTED -> R.drawable.bg_status_closed

            RequestStatus.PENDING -> R.drawable.bg_status_unknown
        }

        fun RequestStatus.colorRes(): Int = when (this) {
            RequestStatus.COMPLETED, RequestStatus.ACCEPTED, RequestStatus.IN_PROGRESS ->
                R.color.status_open

            RequestStatus.CANCELLED, RequestStatus.REJECTED -> R.color.status_closed

            RequestStatus.PENDING -> R.color.status_unknown
        }

        val DIFF = object : DiffUtil.ItemCallback<CustomerRequest>() {
            override fun areItemsTheSame(oldItem: CustomerRequest, newItem: CustomerRequest) =
                oldItem.id == newItem.id

            override fun areContentsTheSame(oldItem: CustomerRequest, newItem: CustomerRequest) =
                oldItem == newItem
        }
    }
}
