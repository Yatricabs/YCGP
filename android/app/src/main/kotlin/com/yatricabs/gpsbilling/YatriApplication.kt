package com.yatricabs.gpsbilling

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

class YatriApplication : Application() {
    companion object {
        const val DIAGNOSTICS_PREFS = "yatri_native_diagnostics"
        const val KEY_DIAGNOSTICS_LOG = "diagnostics_log"
        private const val MAX_DIAGNOSTIC_ENTRIES = 100

        fun appendDiagnostic(prefs: SharedPreferences, type: String, detail: JSONObject) {
            val array = try {
                JSONArray(prefs.getString(KEY_DIAGNOSTICS_LOG, "[]") ?: "[]")
            } catch (_: Exception) {
                JSONArray()
            }
            while (array.length() >= MAX_DIAGNOSTIC_ENTRIES) array.remove(0)
            array.put(JSONObject().apply {
                put("type", type)
                put("timestamp", System.currentTimeMillis())
                put("detail", detail)
            })
            prefs.edit().putString(KEY_DIAGNOSTICS_LOG, array.toString()).apply()
        }
    }

    override fun onCreate() {
        super.onCreate()
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val prefs = getSharedPreferences(DIAGNOSTICS_PREFS, Context.MODE_PRIVATE)
                appendDiagnostic(prefs, "NATIVE_CRASH", JSONObject().apply {
                    put("thread", thread.name)
                    put("exceptionClass", throwable.javaClass.name)
                    put("message", throwable.message ?: "")
                    put("stackTrace", android.util.Log.getStackTraceString(throwable).take(4000))
                    put("rideActive", RideTrackingForegroundService.isRideActive(this@YatriApplication))
                })
            } catch (_: Exception) {
                // Crash diagnostics must never interfere with the original handler.
            }
            previousHandler?.uncaughtException(thread, throwable)
        }
    }
}
