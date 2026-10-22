package com.example.mechanicserviceapp.ui.location

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.example.mechanicserviceapp.databinding.ItemLocationBinding
import com.example.mechanicserviceapp.domain.model.SearchLocation

class LocationAdapter(
    private val onClick: (SearchLocation) -> Unit
) : ListAdapter<SearchLocation, LocationAdapter.LocationViewHolder>(DIFF) {

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = LocationViewHolder(
        ItemLocationBinding.inflate(LayoutInflater.from(parent.context), parent, false)
    )

    override fun onBindViewHolder(holder: LocationViewHolder, position: Int) {
        holder.bind(getItem(position))
    }

    inner class LocationViewHolder(
        private val binding: ItemLocationBinding
    ) : RecyclerView.ViewHolder(binding.root) {

        fun bind(location: SearchLocation) = with(binding) {
            labelText.text = location.label
            coordinatesText.text = root.context.getString(
                com.example.mechanicserviceapp.R.string.location_coords_format,
                location.latitude, location.longitude
            )
            root.setOnClickListener { onClick(location) }
        }
    }

    private companion object {
        val DIFF = object : DiffUtil.ItemCallback<SearchLocation>() {
            override fun areItemsTheSame(oldItem: SearchLocation, newItem: SearchLocation) =
                oldItem.latitude == newItem.latitude && oldItem.longitude == newItem.longitude

            override fun areContentsTheSame(oldItem: SearchLocation, newItem: SearchLocation) =
                oldItem == newItem
        }
    }
}
