package com.example.mechanicserviceapp.ui.home

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.ItemMechanicBinding
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.google.android.material.chip.Chip

class MechanicAdapter(
    private val onClick: (Mechanic) -> Unit
) : ListAdapter<Mechanic, MechanicAdapter.MechanicViewHolder>(DIFF) {

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): MechanicViewHolder {
        val binding = ItemMechanicBinding.inflate(
            LayoutInflater.from(parent.context), parent, false
        )
        return MechanicViewHolder(binding)
    }

    override fun onBindViewHolder(holder: MechanicViewHolder, position: Int) {
        holder.bind(getItem(position))
    }

    inner class MechanicViewHolder(
        private val binding: ItemMechanicBinding
    ) : RecyclerView.ViewHolder(binding.root) {

        fun bind(mechanic: Mechanic) = with(binding) {
            val context = root.context

            nameText.text = mechanic.name
            ratingText.text = context.getString(R.string.rating_format, mechanic.rating)
            reviewCountText.text =
                context.getString(R.string.review_count_format, mechanic.reviewCount)
            distanceText.text =
                context.getString(R.string.distance_format, mechanic.distanceKm)
            locationText.text = mechanic.location

            if (mechanic.isOpen) {
                statusText.setText(R.string.status_open)
                statusText.setBackgroundResource(R.drawable.bg_status_open)
                statusText.setTextColor(context.getColor(R.color.status_open))
            } else {
                statusText.setText(R.string.status_closed)
                statusText.setBackgroundResource(R.drawable.bg_status_closed)
                statusText.setTextColor(context.getColor(R.color.status_closed))
            }

            servicesChipGroup.removeAllViews()
            val inflater = LayoutInflater.from(context)
            mechanic.services.take(MAX_VISIBLE_SERVICES).forEach { service ->
                val chip = inflater.inflate(
                    R.layout.item_service_chip, servicesChipGroup, false
                ) as Chip
                chip.text = service
                chip.isClickable = false
                servicesChipGroup.addView(chip)
            }
            val overflow = mechanic.services.size - MAX_VISIBLE_SERVICES
            if (overflow > 0) {
                val chip = inflater.inflate(
                    R.layout.item_service_chip, servicesChipGroup, false
                ) as Chip
                chip.text = context.getString(R.string.more_services_format, overflow)
                chip.isClickable = false
                servicesChipGroup.addView(chip)
            }

            root.setOnClickListener { onClick(mechanic) }
        }
    }

    private companion object {
        const val MAX_VISIBLE_SERVICES = 3

        val DIFF = object : DiffUtil.ItemCallback<Mechanic>() {
            override fun areItemsTheSame(oldItem: Mechanic, newItem: Mechanic) =
                oldItem.id == newItem.id

            override fun areContentsTheSame(oldItem: Mechanic, newItem: Mechanic) =
                oldItem == newItem
        }
    }
}
