package com.example.mechanicserviceapp.ui.garage

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.core.view.isVisible
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.ItemGarageRequestBinding
import com.example.mechanicserviceapp.domain.model.GarageRequest
import com.example.mechanicserviceapp.domain.model.RequestStatus

/**
 * A job as the garage sees it.
 *
 * Which buttons appear is driven entirely by the status, and mirrors the
 * transitions the database will actually permit — showing a Complete button on
 * a pending job would just produce a server-side rejection.
 */
class GarageRequestAdapter(
    private val onAccept: (GarageRequest) -> Unit,
    private val onReject: (GarageRequest) -> Unit,
    private val onStart: (GarageRequest) -> Unit,
    private val onComplete: (GarageRequest) -> Unit,
    private val onCall: (GarageRequest) -> Unit
) : ListAdapter<GarageRequest, GarageRequestAdapter.ViewHolder>(DIFF) {

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = ViewHolder(
        ItemGarageRequestBinding.inflate(LayoutInflater.from(parent.context), parent, false)
    )

    override fun onBindViewHolder(holder: ViewHolder, position: Int) = holder.bind(getItem(position))

    inner class ViewHolder(
        private val binding: ItemGarageRequestBinding
    ) : RecyclerView.ViewHolder(binding.root) {

        fun bind(request: GarageRequest) = with(binding) {
            val context = root.context

            customerNameText.text = request.customerName.ifBlank { "Customer" }
            serviceText.text = request.serviceName
            vehicleText.text = context.getString(R.string.request_vehicle_format, request.vehicleNumber)
            problemText.text = request.problemDescription

            statusText.text = request.status.label
            statusText.setBackgroundResource(request.status.backgroundRes())
            statusText.setTextColor(context.getColor(request.status.colorRes()))

            val eta = request.etaMinutes
            etaText.isVisible = eta != null
            if (eta != null) etaText.text = context.getString(R.string.request_eta_format, eta)

            noteText.isVisible = !request.mechanicNote.isNullOrBlank()
            noteText.text = request.mechanicNote

            val rating = request.customerRating
            ratingText.isVisible = rating != null
            if (rating != null) {
                ratingText.text = context.getString(R.string.garage_rated_format, rating)
            }

            // A number the garage can actually ring, when the customer gave one.
            callButton.isVisible = request.phoneNumber.isNotBlank()
            callButton.setOnClickListener { onCall(request) }

            acceptButton.isVisible = request.needsDecision
            rejectButton.isVisible = request.needsDecision
            startButton.isVisible = request.canStart
            completeButton.isVisible = request.canComplete

            acceptButton.setOnClickListener { onAccept(request) }
            rejectButton.setOnClickListener { onReject(request) }
            startButton.setOnClickListener { onStart(request) }
            completeButton.setOnClickListener { onComplete(request) }
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

        val DIFF = object : DiffUtil.ItemCallback<GarageRequest>() {
            override fun areItemsTheSame(oldItem: GarageRequest, newItem: GarageRequest) =
                oldItem.id == newItem.id

            override fun areContentsTheSame(oldItem: GarageRequest, newItem: GarageRequest) =
                oldItem == newItem
        }
    }
}
