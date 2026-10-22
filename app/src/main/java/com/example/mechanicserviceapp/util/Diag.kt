package com.example.mechanicserviceapp.util

import android.util.Log
import com.example.mechanicserviceapp.BuildConfig

/**
 * Debug-only tracing for the search path.
 *
 * Added because "no garages outside Pune" could not be pinned down from the
 * outside: the database had the rows and the RPC returned them when called
 * directly, so the only thing left unseen was what the app actually sends. One
 * tag, so a single `adb logcat -s MechSearch` shows the whole journey from the
 * location picker to the row count that came back.
 */
object Diag {
    const val TAG = "MechSearch"

    fun log(message: String) {
        if (BuildConfig.DEBUG) Log.i(TAG, message)
    }

    fun warn(message: String, error: Throwable? = null) {
        if (BuildConfig.DEBUG) Log.w(TAG, message, error)
    }
}
