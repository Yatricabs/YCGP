package com.yatricabs.gpsbilling

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * Genuine user-visible foreground location service for an active YATRI ride.
 *
 * This service is deliberately narrow: it owns Android-side location delivery,
 * a persistent notification and service-health state. Billing validation and
 * route presentation remain in Flutter so the existing v35 billing logic can
 * stay unchanged.
 */
class RideTrackingForegroundService : Service(), LocationListener {
    companion object {
        const val ACTION_START = "com.yatricabs.gpsbilling.START_RIDE"
        const val ACTION_STOP = "com.yatricabs.gpsbilling.STOP_RIDE"
        const val ACTION_UPDATE_NOTIFICATION = "com.yatricabs.gpsbilling.UPDATE_NOTIFICATION"
        const val EVENT_LOCATION = "com.yatricabs.gpsbilling.EVENT_LOCATION"
        const val EVENT_SERVICE = "com.yatricabs.gpsbilling.EVENT_SERVICE"

        private const val CHANNEL_ID = "yatri_active_ride_v2"
        private const val NOTIFICATION_ID = 4107
        private const val PREFS = "yatri_native_ride_service"
        private const val KEY_ACTIVE = "active"
        private const val KEY_SERVICE_STARTED_AT = "service_started_at"
        private const val KEY_LAST_FIX_AT = "last_fix_at"
        private const val KEY_LAST_LAT = "last_lat"
        private const val KEY_LAST_LNG = "last_lng"
        private const val KEY_LAST_ACCURACY = "last_accuracy"
        private const val KEY_LAST_SPEED = "last_speed"
        private const val KEY_STATUS = "status"
        private const val KEY_LAST_TASK_REMOVED_AT = "last_task_removed_at"
        private const val KEY_QUEUE = "queued_fixes"
        private const val MAX_QUEUE = 600

        @Volatile
        private var instance: RideTrackingForegroundService? = null

        @Volatile
        var flutterListenerAttached: Boolean = false

        fun isRideActive(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_ACTIVE, false)

        fun serviceHealth(context: Context): String {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return JSONObject().apply {
                put("active", prefs.getBoolean(KEY_ACTIVE, false))
                put("serviceAlive", instance != null)
                put("serviceStartedAt", prefs.getLong(KEY_SERVICE_STARTED_AT, 0L))
                put("lastFixAt", prefs.getLong(KEY_LAST_FIX_AT, 0L))
                put("lastLat", prefs.getString(KEY_LAST_LAT, null))
                put("lastLng", prefs.getString(KEY_LAST_LNG, null))
                put("lastAccuracy", prefs.getFloat(KEY_LAST_ACCURACY, -1f).toDouble())
                put("lastSpeedMps", prefs.getFloat(KEY_LAST_SPEED, -1f).toDouble())
                put("status", prefs.getString(KEY_STATUS, "UNKNOWN"))
                put("lastTaskRemovedAt", prefs.getLong(KEY_LAST_TASK_REMOVED_AT, 0L))
                put("queuedFixCount", queueSize(prefs))
            }.toString()
        }

        fun drainQueuedLocations(context: Context): List<String> {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val raw = prefs.getString(KEY_QUEUE, null) ?: return emptyList()
            prefs.edit().remove(KEY_QUEUE).apply()
            val result = ArrayList<String>()
            try {
                val array = JSONArray(raw)
                for (i in 0 until array.length()) result.add(array.getString(i))
            } catch (_: Exception) {
                // Corrupt queue is discarded rather than crashing ride recovery.
            }
            return result
        }

        private fun queueSize(prefs: SharedPreferences): Int {
            return try {
                prefs.getString(KEY_QUEUE, null)?.let { JSONArray(it).length() } ?: 0
            } catch (_: Exception) {
                0
            }
        }

        fun updateNotification(context: Context, distanceText: String, speedText: String, status: String) {
            instance?.showNotification(distanceText, speedText, status)
        }

        fun getDiagnosticsLog(context: Context): String = context
            .getSharedPreferences(YatriApplication.DIAGNOSTICS_PREFS, Context.MODE_PRIVATE)
            .getString(YatriApplication.KEY_DIAGNOSTICS_LOG, "[]") ?: "[]"

        fun clearDiagnosticsLog(context: Context) {
            context.getSharedPreferences(YatriApplication.DIAGNOSTICS_PREFS, Context.MODE_PRIVATE)
                .edit().remove(YatriApplication.KEY_DIAGNOSTICS_LOG).apply()
        }
    }

    private lateinit var locationManager: LocationManager
    private lateinit var prefs: SharedPreferences
    private var lastLocation: Location? = null
    private var slowPolling = false
    private var lastPollingSwitchElapsed = 0L
    private var wakeLock: PowerManager.WakeLock? = null
    private val watchdogHandler = Handler(Looper.getMainLooper())
    private val watchdogRunnable = object : Runnable {
        override fun run() {
            if (prefs.getBoolean(KEY_ACTIVE, false)) {
                val lastFixAt = prefs.getLong(KEY_LAST_FIX_AT, 0L)
                val silenceMs = System.currentTimeMillis() - lastFixAt
                if (lastFixAt > 0L && silenceMs > 45_000L) {
                    appendDiagnostic("GPS_FIX_STALLED_AUTO_RECOVERED", JSONObject().apply {
                        put("silenceMs", silenceMs)
                    })
                    requestLocationUpdates()
                }
                watchdogHandler.postDelayed(this, 30_000L)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == null && prefs.getBoolean(KEY_ACTIVE, false)) {
            // START_STICKY may recreate the service after process pressure.
            // Re-enter the exact same genuine active-ride setup instead of
            // waiting for Flutter to notice the restart.
            startRideService()
            return START_STICKY
        }
        when (action) {
            ACTION_START -> startRideService()
            ACTION_STOP -> stopRideService()
            ACTION_UPDATE_NOTIFICATION -> {
                showNotification(
                    intent.getStringExtra("distance") ?: "0.0km",
                    intent.getStringExtra("speed") ?: "0km/h",
                    intent.getStringExtra("status") ?: "Active ride",
                )
            }
        }
        return START_STICKY
    }

    private fun startRideService() {
        if (!hasLocationPermission()) {
            broadcastServiceEvent("LOCATION_PERMISSION_MISSING")
            stopSelf()
            return
        }

        try {
            val notification = buildNotification("0.0km", "0km/h", "Ride tracking active")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceCompat.startForeground(
                    this,
                    NOTIFICATION_ID,
                    notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }

            prefs.edit()
                .putBoolean(KEY_ACTIVE, true)
                .putLong(KEY_SERVICE_STARTED_AT, System.currentTimeMillis())
                .putString(KEY_STATUS, "RUNNING")
                .apply()

            acquireWakeLock()
            requestLocationUpdates()
            watchdogHandler.removeCallbacks(watchdogRunnable)
            watchdogHandler.postDelayed(watchdogRunnable, 30_000L)
            broadcastServiceEvent("RUNNING")
        } catch (security: SecurityException) {
            prefs.edit().putString(KEY_STATUS, "START_PERMISSION_ERROR").apply()
            broadcastServiceEvent("START_PERMISSION_ERROR", security.message)
            stopForegroundCompat()
            stopSelf()
        } catch (error: Exception) {
            prefs.edit().putString(KEY_STATUS, "START_ERROR").apply()
            broadcastServiceEvent("START_ERROR", error.message)
            stopForegroundCompat()
            stopSelf()
        }
    }

    private fun stopRideService() {
        watchdogHandler.removeCallbacks(watchdogRunnable)
        releaseWakeLock()
        removeLocationUpdates()
        prefs.edit().putBoolean(KEY_ACTIVE, false).putString(KEY_STATUS, "STOPPED").apply()
        broadcastServiceEvent("STOPPED")
        stopForegroundCompat()
        stopSelf()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = manager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "YatriCabs:RideTracking").apply {
                setReferenceCounted(false)
                acquire(12 * 60 * 60 * 1000L)
            }
        } catch (_: Exception) {
            // GPS tracking remains functional without the optional wake lock.
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
            // Safe teardown.
        }
        wakeLock = null
    }

    private fun requestLocationUpdates() {
        removeLocationUpdates()
        val intervalMs = if (slowPolling) 8000L else 2000L
        val minDistanceM = if (slowPolling) 4f else 0f
        if (!hasLocationPermission()) return
        if (!locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            prefs.edit().putString(KEY_STATUS, "GPS_DISABLED").apply()
            broadcastServiceEvent("GPS_DISABLED")
            return
        }
        locationManager.requestLocationUpdates(
            LocationManager.GPS_PROVIDER,
            intervalMs,
            minDistanceM,
            this,
            mainLooper,
        )
        prefs.edit().putString(KEY_STATUS, "GPS_LISTENING").apply()
    }

    private fun removeLocationUpdates() {
        try {
            locationManager.removeUpdates(this)
        } catch (_: Exception) {
            // Safe teardown path.
        }
    }

    override fun onLocationChanged(location: Location) {
        if (!prefs.getBoolean(KEY_ACTIVE, false)) return
        lastLocation = location
        prefs.edit()
            .putLong(KEY_LAST_FIX_AT, System.currentTimeMillis())
            .putString(KEY_LAST_LAT, location.latitude.toString())
            .putString(KEY_LAST_LNG, location.longitude.toString())
            .putFloat(KEY_LAST_ACCURACY, location.accuracy)
            .putFloat(KEY_LAST_SPEED, if (location.hasSpeed()) location.speed else -1f)
            .putString(KEY_STATUS, "GPS_ACTIVE")
            .apply()

        val event = JSONObject().apply {
            put("type", "location")
            put("latitude", location.latitude)
            put("longitude", location.longitude)
            put("accuracy", location.accuracy.toDouble())
            put("altitude", if (location.hasAltitude()) location.altitude else 0.0)
            put("speed", if (location.hasSpeed()) location.speed else 0.0)
            put("heading", if (location.hasBearing()) location.bearing else 0.0)
            put("timestamp", location.time)
            put("elapsedRealtimeNanos", location.elapsedRealtimeNanos)
            put("isMocked", if (Build.VERSION.SDK_INT >= 31) location.isMock else false)
        }.toString()

        if (flutterListenerAttached) {
            broadcast(EVENT_LOCATION, event)
        } else {
            enqueueFix(event)
        }
        broadcastServiceEvent("GPS_ACTIVE")
    }

    private fun enqueueFix(event: String) {
        val array = try {
            JSONArray(prefs.getString(KEY_QUEUE, "[]") ?: "[]")
        } catch (_: Exception) {
            JSONArray()
        }
        while (array.length() >= MAX_QUEUE) {
            array.remove(0)
        }
        array.put(event)
        prefs.edit().putString(KEY_QUEUE, array.toString()).apply()
    }

    private fun switchPollingIfNeeded() {
        val current = lastLocation ?: return
        val speed = if (current.hasSpeed()) current.speed else 0f
        val shouldSlow = speed >= 0f && speed < 1.5f
        val now = SystemClock.elapsedRealtime()
        if (shouldSlow == slowPolling) return
        if (now - lastPollingSwitchElapsed < 15_000L) return
        slowPolling = shouldSlow
        lastPollingSwitchElapsed = now
        requestLocationUpdates()
    }

    private fun showNotification(distanceText: String, speedText: String, status: String) {
        if (!prefs.getBoolean(KEY_ACTIVE, false)) return
        createNotificationChannel()
        val manager = getSystemService(NotificationManager::class.java)
        try {
            manager.notify(NOTIFICATION_ID, buildNotification(distanceText, speedText, status))
        } catch (error: Exception) {
            broadcastServiceEvent("NOTIFICATION_UPDATE_ERROR", error.message)
        }
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(distanceText: String, speedText: String, status: String): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            4108,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        return builder
            .setSmallIcon(R.drawable.ic_stat_location)
            .setContentTitle("YATRI CABS • Ride Active")
            .setContentText("$distanceText • $speedText")
            .setSubText(status)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Active ride tracking",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "Shows the active YATRI CABS ride tracking state."
            setShowBadge(false)
            enableVibration(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    private fun broadcast(action: String, payload: String) {
        sendBroadcast(Intent(action).setPackage(packageName).putExtra("payload", payload))
    }

    private fun broadcastServiceEvent(status: String, detail: String? = null) {
        val payload = JSONObject().apply {
            put("type", "service")
            put("status", status)
            put("active", prefs.getBoolean(KEY_ACTIVE, false))
            put("timestamp", System.currentTimeMillis())
            if (detail != null) put("detail", detail)
        }.toString()
        broadcast(EVENT_SERVICE, payload)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (prefs.getBoolean(KEY_ACTIVE, false)) {
            prefs.edit().putLong(KEY_LAST_TASK_REMOVED_AT, System.currentTimeMillis()).apply()
            appendDiagnostic("APP_SWIPED_FROM_RECENTS", JSONObject().apply {
                put("batteryPercent", batteryPercent())
            })
            showNotification("Ride active", "GPS running", "YATRI continues in background")
            broadcastServiceEvent("TASK_REMOVED")
            vibrateOnce()
            requestLocationUpdates()
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        watchdogHandler.removeCallbacks(watchdogRunnable)
        releaseWakeLock()
        removeLocationUpdates()
        if (prefs.getBoolean(KEY_ACTIVE, false)) {
            appendDiagnostic("SERVICE_KILLED_UNEXPECTEDLY", JSONObject().apply {
                put("batteryPercent", batteryPercent())
                put("screenInteractive", isScreenInteractive())
                val lastFixAt = prefs.getLong(KEY_LAST_FIX_AT, 0L)
                put("msSinceLastFix", if (lastFixAt > 0L) System.currentTimeMillis() - lastFixAt else -1L)
            })
            prefs.edit().putString(KEY_STATUS, "KILLED_UNEXPECTEDLY").apply()
        }
        if (instance === this) instance = null
        super.onDestroy()
    }

    private fun appendDiagnostic(type: String, detail: JSONObject) {
        try {
            val diagnostics = getSharedPreferences(YatriApplication.DIAGNOSTICS_PREFS, Context.MODE_PRIVATE)
            YatriApplication.appendDiagnostic(diagnostics, type, detail)
        } catch (_: Exception) {
            // Diagnostics are best effort and must not affect tracking.
        }
    }

    private fun batteryPercent(): Int = try {
        (getSystemService(Context.BATTERY_SERVICE) as BatteryManager)
            .getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
    } catch (_: Exception) {
        -1
    }

    private fun isScreenInteractive(): Boolean = try {
        (getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive
    } catch (_: Exception) {
        true
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun hasLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
    }

    private fun vibrateOnce() {
        try {
            val vibrator = getSystemService(Vibrator::class.java) ?: return
            if (Build.VERSION.SDK_INT >= 26) {
                vibrator.vibrate(VibrationEffect.createOneShot(120, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(120)
            }
        } catch (_: Exception) {
            // Vibration is best-effort only.
        }
    }
}
