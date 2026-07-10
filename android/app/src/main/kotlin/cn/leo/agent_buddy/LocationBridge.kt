package cn.leo.agent_buddy

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.Geocoder
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * MethodChannel bridge for the device's GPS location.
 *
 * Channel: `agent_buddy/location`
 *
 * Methods:
 *   - ensurePermission
 *   - getCurrentLocation(timeoutMs)
 *
 * Uses Google Play Services' FusedLocationProviderClient so the
 * app does not need to pick a specific provider (gps / network /
 * passive).
 *
 * Permission flow:
 *   - Both methods check first; if not yet granted and not yet
 *     asked, we call `requestPermissions` with FINE + COARSE.
 *   - The original call's result is parked in [pendingResults] keyed
 *     by a synthetic call id. When the user responds via
 *     `onRequestPermissionsResult` we resume every parked call:
 *     a granted call delivers the result, a denied call surfaces
 *     PERMISSION_DENIED.
 *   - Permanent denial (user has tapped "Don't ask again") is
 *     detected via the SharedPreferences flag we set on the first
 *     request: if `shouldShowRequestPermissionRationale` returns
 *     false *and* we asked before, treat it as permanently denied
 *     so the UI can prompt the user to open system settings.
 */
class LocationBridge(
    private val context: Context,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {

    companion object {
        const val CHANNEL = "agent_buddy/location"
        private const val PERMISSION_REQUEST_CODE = 9003
    }

    private val fused: FusedLocationProviderClient by lazy {
        LocationServices.getFusedLocationProviderClient(context)
    }

    private data class Pending(
        val result: MethodChannel.Result,
        val kind: Kind,
        val timeoutMs: Long,
        val delivered: AtomicBoolean,
    )
    private enum class Kind { ENSURE, FETCH }

    private val pendingResults: MutableMap<String, Pending> = ConcurrentHashMap()
    private val callSeq: java.util.concurrent.atomic.AtomicInteger =
        java.util.concurrent.atomic.AtomicInteger(0)
    private var permissionRequestInFlight: Boolean = false

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(this)
    }

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "ensurePermission" -> handleEnsure(result)
            "getCurrentLocation" -> {
                val args = call.arguments as? Map<String, Any?>
                val timeoutMs = (args?.get("timeoutMs") as? Number)?.toLong() ?: 10_000L
                handleFetch(result, timeoutMs)
            }
            else -> result.notImplemented()
        }
    }

    // -------- Ensure --------

    private fun handleEnsure(result: MethodChannel.Result) {
        if (hasPermission()) {
            result.success(permissionStatusMap())
            return
        }
        if (currentStatus() == "permanently_denied") {
            result.success(permissionStatusMap())
            return
        }
        val callId = nextCallId()
        pendingResults[callId] = Pending(
            result = result,
            kind = Kind.ENSURE,
            timeoutMs = 0L,
            delivered = AtomicBoolean(false),
        )
        requestPermissionIfNeeded()
    }

    // -------- Fetch --------

    private fun handleFetch(result: MethodChannel.Result, timeoutMs: Long) {
        if (hasPermission()) {
            fetchLocation(result, timeoutMs)
            return
        }
        if (currentStatus() == "permanently_denied") {
            result.error(
                "PERMISSION_DENIED",
                "Location permission permanently denied; open system settings to enable it",
                null,
            )
            return
        }
        val callId = nextCallId()
        pendingResults[callId] = Pending(
            result = result,
            kind = Kind.FETCH,
            timeoutMs = timeoutMs,
            delivered = AtomicBoolean(false),
        )
        requestPermissionIfNeeded()
    }

    // -------- Permission --------

    private fun hasPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        if (fine) return true
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun currentStatus(): String =
        if (hasPermission()) "granted"
        else if (!ActivityCompat.shouldShowRequestPermissionRationale(
                activity,
                Manifest.permission.ACCESS_FINE_LOCATION,
            ) && hasEverRequested()
        ) "permanently_denied"
        else "denied"

    private fun permissionStatusMap(): Map<String, Any> {
        if (hasPermission()) {
            return mapOf("granted" to true, "status" to "granted")
        }
        val status = currentStatus()
        return mapOf(
            "granted" to false,
            "status" to if (status == "permanently_denied") "permanently_denied" else "denied",
        )
    }

    private fun hasEverRequested(): Boolean {
        val prefs = context.getSharedPreferences(
            "agent_buddy_prefs",
            Context.MODE_PRIVATE,
        )
        return prefs.getBoolean("location_permission_requested", false)
    }

    private fun markPermissionRequested() {
        context.getSharedPreferences("agent_buddy_prefs", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("location_permission_requested", true)
            .apply()
    }

    private fun requestPermissionIfNeeded() {
        if (permissionRequestInFlight) return
        permissionRequestInFlight = true
        markPermissionRequested()
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            PERMISSION_REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        permissionRequestInFlight = false
        val snapshot = pendingResults.toMap()
        pendingResults.clear()

        if (!hasPermission()) {
            // Permanent denial or first-time decline. We can't tell
            // the two apart from grantResults alone, so re-check
            // currentStatus: if it's permanently_denied we surface
            // that, otherwise plain PERMISSION_DENIED.
            val isPermanent = currentStatus() == "permanently_denied"
            for ((_, p) in snapshot) {
                if (p.delivered.compareAndSet(false, true)) {
                    when (p.kind) {
                        Kind.ENSURE -> p.result.success(permissionStatusMap())
                        Kind.FETCH -> p.result.error(
                            if (isPermanent) "PERMANENTLY_DENIED" else "PERMISSION_DENIED",
                            "Location permission was denied; please grant it in system settings.",
                            null,
                        )
                    }
                }
            }
            return true
        }

        for ((_, p) in snapshot) {
            if (!p.delivered.compareAndSet(false, true)) continue
            when (p.kind) {
                Kind.ENSURE -> p.result.success(permissionStatusMap())
                Kind.FETCH -> fetchLocation(p.result, p.timeoutMs)
            }
        }
        return true
    }

    // -------- Fetch --------

    @SuppressLint("MissingPermission")
    private fun fetchLocation(result: MethodChannel.Result, timeoutMs: Long) {
        val delivered = AtomicBoolean(false)
        val safeSuccess: (Map<String, Any?>) -> Unit = { payload ->
            if (delivered.compareAndSet(false, true)) {
                result.success(payload)
            }
        }
        val safeError: (String, String) -> Unit = { code, message ->
            if (delivered.compareAndSet(false, true)) {
                result.error(code, message, null)
            }
        }
        val cts = CancellationTokenSource()
        fused.getCurrentLocation(
            Priority.PRIORITY_BALANCED_POWER_ACCURACY,
            cts.token,
        ).addOnSuccessListener { loc ->
            if (loc != null) {
                handleFix(safeSuccess, loc.latitude, loc.longitude, loc.accuracy)
                return@addOnSuccessListener
            }
            fused.lastLocation
                .addOnSuccessListener { last ->
                    if (last == null) {
                        cts.cancel()
                        safeError(
                            "LOCATION_UNAVAILABLE",
                            "no fix available; enable location services and try again",
                        )
                    } else {
                        handleFix(safeSuccess, last.latitude, last.longitude, last.accuracy)
                    }
                }
                .addOnFailureListener { e ->
                    cts.cancel()
                    safeError("LOCATION_UNAVAILABLE", e.message ?: "unknown")
                }
        }.addOnFailureListener { e ->
            cts.cancel()
            safeError("LOCATION_UNAVAILABLE", e.message ?: "unknown")
        }

        // FusedLocationProviderClient doesn't honour a timeout. Race
        // one against the listener above.
        Thread {
            try {
                TimeUnit.MILLISECONDS.sleep(timeoutMs)
                if (delivered.compareAndSet(false, true)) {
                    cts.cancel()
                    result.error(
                        "LOCATION_TIMEOUT",
                        "location request timed out after ${timeoutMs}ms",
                        null,
                    )
                }
            } catch (_: InterruptedException) {}
        }.start()
    }

    private fun handleFix(
        deliver: (Map<String, Any?>) -> Unit,
        lat: Double,
        lon: Double,
        accuracy: Float,
    ) {
        var city: String? = null
        var region: String? = null
        var country: String? = null
        var countryCode: String? = null
        try {
            if (Geocoder.isPresent()) {
                val addresses = Geocoder(context, Locale.getDefault())
                    .getFromLocation(lat, lon, 1)
                if (!addresses.isNullOrEmpty()) {
                    val a = addresses[0]
                    city = a.locality ?: a.subAdminArea
                    region = a.adminArea
                    country = a.countryName
                    countryCode = a.countryCode
                }
            }
        } catch (_: Exception) {
            // Best effort — coordinates alone are still useful.
        }

        val tz = java.util.TimeZone.getDefault().id
        deliver(
            mapOf(
                "latitude" to lat,
                "longitude" to lon,
                "accuracyMeters" to accuracy.toDouble(),
                "city" to city,
                "region" to region,
                "country" to country,
                "countryCode" to countryCode,
                "timezone" to tz,
                "source" to "gps",
                "fetchedAtMs" to System.currentTimeMillis(),
            ),
        )
    }

    private fun nextCallId(): String = "loc-${callSeq.incrementAndGet()}"
}
