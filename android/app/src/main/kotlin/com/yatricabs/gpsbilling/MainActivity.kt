package com.yatricabs.gpsbilling

import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHOD_CHANNEL = "yatri_cabs/ride_service"
        private const val EVENT_CHANNEL = "yatri_cabs/ride_events"
    }

    private var eventSink: EventChannel.EventSink? = null
    private var receiverRegistered = false

    private val rideEventReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val payload = intent?.getStringExtra("payload") ?: return
            eventSink?.success(payload)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "startRideService" -> {
                    startRideService()
                    result.success(true)
                }
                "stopRideService" -> {
                    stopRideService()
                    result.success(true)
                }
                "getServiceHealth" -> result.success(RideTrackingForegroundService.serviceHealth(this))
                "drainQueuedLocations" -> result.success(RideTrackingForegroundService.drainQueuedLocations(this))
                "updateNotification" -> {
                    RideTrackingForegroundService.updateNotification(
                        this,
                        call.argument<String>("distance") ?: "0.0km",
                        call.argument<String>("speed") ?: "0km/h",
                        call.argument<String>("status") ?: "Active ride",
                    )
                    result.success(true)
                }
                "getDeviceProfile" -> result.success(
                    mapOf(
                        "manufacturer" to Build.MANUFACTURER,
                        "brand" to Build.BRAND,
                        "model" to Build.MODEL,
                        "androidSdk" to Build.VERSION.SDK_INT,
                        "release" to Build.VERSION.RELEASE,
                    )
                )
                "enterPip" -> {
                    enterRidePip()
                    result.success(true)
                }
                "closeTask" -> {
                    finishAndRemoveTask()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    RideTrackingForegroundService.flutterListenerAttached = true
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    RideTrackingForegroundService.flutterListenerAttached = false
                }
            },
        )
    }

    override fun onStart() {
        super.onStart()
        registerRideReceiver()
    }

    private fun registerRideReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(RideTrackingForegroundService.EVENT_LOCATION)
            addAction(RideTrackingForegroundService.EVENT_SERVICE)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(rideEventReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(rideEventReceiver, filter)
        }
        receiverRegistered = true
    }

    private fun unregisterRideReceiver() {
        try {
            unregisterReceiver(rideEventReceiver)
        } catch (_: IllegalArgumentException) {
            // Receiver was already unregistered.
        }
        receiverRegistered = false
    }

    override fun onDestroy() {
        unregisterRideReceiver()
        eventSink = null
        RideTrackingForegroundService.flutterListenerAttached = false
        super.onDestroy()
    }

    private fun startRideService() {
        val intent = Intent(this, RideTrackingForegroundService::class.java).apply {
            action = RideTrackingForegroundService.ACTION_START
        }
        if (Build.VERSION.SDK_INT >= 26) {
            ContextCompat.startForegroundService(this, intent)
        } else {
            startService(intent)
        }
    }

    private fun stopRideService() {
        val intent = Intent(this, RideTrackingForegroundService::class.java).apply {
            action = RideTrackingForegroundService.ACTION_STOP
        }
        // End Ride is triggered from the visible Activity, so a normal
        // startService call is appropriate and lets the service clear its
        // persisted active-ride state before stopping itself.
        startService(intent)
    }

    private fun enterRidePip() {
        if (Build.VERSION.SDK_INT < 26) return
        try {
            val paramsBuilder = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(16, 9))
            if (Build.VERSION.SDK_INT >= 31) {
                paramsBuilder.setAutoEnterEnabled(true)
                paramsBuilder.setSeamlessResizeEnabled(true)
            }
            enterPictureInPictureMode(paramsBuilder.build())
        } catch (_: Exception) {
            // PiP is optional; the ride service is independent of it.
        }
    }

    override fun onUserLeaveHint() {
        if (RideTrackingForegroundService.isRideActive(this)) {
            enterRidePip()
        }
        super.onUserLeaveHint()
    }

    @Deprecated("Deprecated in Android API 33; kept for API compatibility.")
    override fun onBackPressed() {
        if (RideTrackingForegroundService.isRideActive(this)) {
            enterRidePip()
            return
        }
        super.onBackPressed()
    }
}
