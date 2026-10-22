package com.example.mechanicserviceapp.data

import android.location.Location
import android.location.LocationManager
import android.Manifest
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.example.mechanicserviceapp.data.repository.LocationRepositoryImpl
import com.example.mechanicserviceapp.util.Resource
import com.google.android.gms.location.LocationServices
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.tasks.await
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

/**
 * Covers the bug that made "use my location" report the wrong place.
 *
 * `currentLocation()` used to hand back `FusedLocationProviderClient.lastLocation`
 * with no age check. On an emulator that cache is the hardcoded Googleplex fix
 * (37.421998, -122.084000), so the app confidently reported Mountain View and
 * searched for garages there.
 *
 * These run against a real device/emulator because FusedLocationProviderClient is
 * not something worth faking — the whole bug was about what that API actually
 * returns, so a mock of it would have happily reproduced my wrong assumption.
 *
 * Self-contained: the instrumentation run reinstalls the app, which clears both the
 * runtime permissions and the mock-location app op, so the test grants its own.
 *
 * These SKIP rather than fail where the platform will not feed a position through
 * FusedLocationProviderClient. The stock Pixel AVD image is one such place:
 * setMockMode and setMockLocation both report success and then every read comes
 * back null, and even a real `adb emu geo fix` does not reach Play Services. There
 * is nothing to assert about resolution logic on a device that resolves nothing, and
 * a test that fails for that reason is just noise. On hardware, or any image whose
 * fused provider works, they run for real.
 */
@RunWith(AndroidJUnit4::class)
class LocationRepositoryTest {

    @get:Rule
    val locationPermissions: GrantPermissionRule = GrantPermissionRule.grant(
        Manifest.permission.ACCESS_FINE_LOCATION,
        Manifest.permission.ACCESS_COARSE_LOCATION
    )

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val fused = LocationServices.getFusedLocationProviderClient(context)

    /** Only `context` and the fused client are touched by currentLocation(). */
    private val repository = LocationRepositoryImpl(
        context = context,
        postgrestProvider = { error("postgrest must not be touched by currentLocation()") },
        authProvider = { error("auth must not be touched by currentLocation()") }
    )

    // Block bodies, not expression bodies: Task<Void>.await() returns Void?, which
    // JUnit rejects because a fixture method has to be void.
    /** True when the platform actually honours the mock location we set. */
    private var mockLocationWorks = false

    @Before
    fun enableMockMode() {
        // GrantPermissionRule covers runtime permissions but not app ops, and
        // setMockLocation needs this one. Reset by every reinstall, so do it here.
        instrumentation.uiAutomation
            .executeShellCommand("appops set ${context.packageName} android:mock_location allow")
            .close()
        runBlocking {
            runCatching { fused.setMockMode(true).await() }
            // Probe once: push a fix and see whether anything reads back.
            runCatching { fused.setMockLocation(fixAt(KOTHRUD_LAT, KOTHRUD_LNG)).await() }
            mockLocationWorks = runCatching { fused.lastLocation.await() }.getOrNull() != null
        }
    }

    @After
    fun disableMockMode() {
        runBlocking { runCatching { fused.setMockMode(false).await() } }
    }

    private fun fixAt(latitude: Double, longitude: Double) =
        Location(LocationManager.FUSED_PROVIDER).apply {
            this.latitude = latitude
            this.longitude = longitude
            accuracy = 5f
            time = System.currentTimeMillis()
            elapsedRealtimeNanos = android.os.SystemClock.elapsedRealtimeNanos()
        }

    /**
     * Keeps publishing a mock fix for as long as [block] runs.
     *
     * `setMockLocation` is a single push to whatever is listening at that instant.
     * Setting it once and then calling `currentLocation()` delivers it to nobody —
     * the request starts afterwards and waits for an update that never comes. A real
     * provider emits continuously, so the mock has to as well.
     */
    private suspend fun <T> whileLocatedAt(
        latitude: Double,
        longitude: Double,
        block: suspend () -> T
    ): T = coroutineScope {
        val pump = launch {
            while (isActive) {
                runCatching { fused.setMockLocation(fixAt(latitude, longitude)).await() }
                delay(PUMP_INTERVAL_MS)
            }
        }
        try {
            block()
        } finally {
            pump.cancel()
        }
    }

    @Test
    fun currentLocation_returnsTheFixThatIsActuallySet() = runBlocking {
        assumeTrue("fused provider does not honour mock locations here", mockLocationWorks)
        val result = whileLocatedAt(KOTHRUD_LAT, KOTHRUD_LNG) { repository.currentLocation() }

        assertTrue("expected a location, got $result", result is Resource.Success)
        val location = (result as Resource.Success).data

        assertEquals("latitude", KOTHRUD_LAT, location.latitude, TOLERANCE_DEGREES)
        assertEquals("longitude", KOTHRUD_LNG, location.longitude, TOLERANCE_DEGREES)
    }

    /**
     * The regression itself. Mountain View is ~13,000 km from Pune, so any drift
     * towards it means the stale cache leaked through again.
     */
    @Test
    fun currentLocation_doesNotReturnTheEmulatorsDefaultGooglePlexFix() = runBlocking {
        assumeTrue("fused provider does not honour mock locations here", mockLocationWorks)
        val result = whileLocatedAt(KOTHRUD_LAT, KOTHRUD_LNG) { repository.currentLocation() }
        assertTrue(result is Resource.Success)
        val location = (result as Resource.Success).data

        val nearGooglePlex =
            abs(location.latitude - GOOGLEPLEX_LAT) < 0.5 &&
                abs(location.longitude - GOOGLEPLEX_LNG) < 0.5
        assertTrue(
            "returned the emulator's stale default fix " +
                "(${location.latitude}, ${location.longitude})",
            !nearGooglePlex
        )
    }

    @Test
    fun currentLocation_followsTheDeviceWhenItMoves() = runBlocking {
        assumeTrue("fused provider does not honour mock locations here", mockLocationWorks)
        val first = whileLocatedAt(KOTHRUD_LAT, KOTHRUD_LNG) { repository.currentLocation() }
        assertTrue(first is Resource.Success)

        // Somewhere unmistakably different: Hyderabad, ~500 km away.
        val second = whileLocatedAt(HYDERABAD_LAT, HYDERABAD_LNG) { repository.currentLocation() }
        assertTrue(second is Resource.Success)

        val moved = (second as Resource.Success).data
        assertEquals("latitude", HYDERABAD_LAT, moved.latitude, TOLERANCE_DEGREES)
        assertEquals("longitude", HYDERABAD_LNG, moved.longitude, TOLERANCE_DEGREES)
    }

    @Test
    fun permissionCheckSeesTheGrantsTheTestRunHas() {
        assertTrue("coarse should be granted", repository.hasLocationPermission())
    }

    private companion object {
        const val KOTHRUD_LAT = 18.5074
        const val KOTHRUD_LNG = 73.8077
        const val HYDERABAD_LAT = 17.3850
        const val HYDERABAD_LNG = 78.4867
        const val GOOGLEPLEX_LAT = 37.421998
        const val GOOGLEPLEX_LNG = -122.084000

        /** ~1 km, which also tolerates the coarse-permission grid if fine is denied. */
        const val TOLERANCE_DEGREES = 0.02
        const val PUMP_INTERVAL_MS = 200L
    }
}
