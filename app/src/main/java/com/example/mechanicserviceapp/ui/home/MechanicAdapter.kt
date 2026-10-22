package com.example.mechanicserviceapp.ui.home

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.core.view.isVisible
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.example.mechanicserviceapp.R
import com.example.mechanicserviceapp.databinding.ItemMechanicBinding
import com.example.mechanicserviceapp.domain.model.Mechanic
import com.google.android.material.chip.Chip

/**
 * Renders a garage card.
 *
 * Most of the work here is deciding what *not* to draw. These are real listings and
 * the majority are missing a rating, hours, or both, so each of those elements is
 * hidden rather than filled with a zero or a guess.
 */
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

            nameText.text = mechanic.displayName
            secondaryNameText.isVisible = mechanic.secondaryName != null
            secondaryNameText.text = mechanic.secondaryName

            // A rating exists only once somebody has left one. No reviews means the
            // pill goes away and we say so, rather than showing "0.0".
            val rating = mechanic.rating
            ratingPill.isVisible = rating != null
            noRatingText.isVisible = rating == null
            reviewCountText.isVisible = rating != null
            if (rating != null) {
                ratingText.text = context.getString(R.string.rating_format, rating)
                reviewCountText.text = if (mechanic.reviewCount == 1) {
                    context.getString(R.string.review_count_one)
                } else {
                    context.getString(R.string.review_count_format, mechanic.reviewCount)
                }
            }

            val distance = mechanic.distanceKm
            distanceText.isVisible = distance != null
            dotSeparator.isVisible = distance != null
            if (distance != null) {
                distanceText.text = context.getString(R.string.distance_format, distance)
            }

            val location = mechanic.displayLocation
            locationText.isVisible = location != null
            locationText.text = location

            bindStatus(mechanic)
            bindServices(mechanic)

            root.setOnClickListener { onClick(mechanic) }
        }

        /**
         * Three states, not two. A null [Mechanic.isOpen] means nobody has recorded
         * this garage's hours — the old model collapsed that into "Closed", which
         * told the user something untrue about a garage that may well be open.
         */
        private fun bindStatus(mechanic: Mechanic) = with(binding) {
            val context = root.context
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

        private fun bindServices(mechanic: Mechanic) = with(binding) {
            val context = root.context
            servicesChipGroup.removeAllViews()
            servicesChipGroup.isVisible = mechanic.services.isNotEmpty()

            val inflater = LayoutInflater.from(context)
            fun addChip(label: String) {
                val chip = inflater.inflate(
                    R.layout.item_service_chip, servicesChipGroup, false
                ) as Chip
                chip.text = label
                chip.isClickable = false
                servicesChipGroup.addView(chip)
            }

            mechanic.services.take(MAX_VISIBLE_SERVICES).forEach(::addChip)
            val overflow = mechanic.services.size - MAX_VISIBLE_SERVICES
            if (overflow > 0) addChip(context.getString(R.string.more_services_format, overflow))
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
