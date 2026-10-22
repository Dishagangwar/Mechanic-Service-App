package com.example.mechanicserviceapp.util

import com.example.mechanicserviceapp.BuildConfig

/**
 * The Supabase credentials baked in at build time from local.properties.
 *
 * A fresh clone has neither value set, so [isConfigured] lets the app come up and say so on
 * screen instead of dying during injection with an explanation only logcat ever sees.
 */
object SupabaseConfig {

    val url: String = BuildConfig.SUPABASE_URL

    val anonKey: String = BuildConfig.SUPABASE_ANON_KEY

    val isConfigured: Boolean = url.isNotBlank() && anonKey.isNotBlank()

    const val SETUP_MESSAGE: String =
        "Add SUPABASE_URL and SUPABASE_ANON_KEY to local.properties, then re-sync Gradle " +
            "and run again. Both are in your Supabase dashboard under Project Settings > API."
}
