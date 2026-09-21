package com.crosstransfer.crosstransfer

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Build
import android.Manifest
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val mobile get() = (application as TransferApplication).mobile
    override fun provideFlutterEngine(context: Context): FlutterEngine = (application as TransferApplication).engine
    override fun shouldDestroyEngineWithHost() = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        mobile.Attach(this)
        if (savedInstanceState == null) mobile.ImportIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        mobile.ImportIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        mobile.Foreground()
    }

    override fun onPostResume() {
        super.onPostResume()
        // The Application can start Dart before an Activity is attached. Ask
        // here so plugin initialization never dereferences a missing Activity.
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            val preferences = getSharedPreferences("permissions", MODE_PRIVATE)
            if (!preferences.getBoolean("notifications_asked", false)) {
                preferences.edit().putBoolean("notifications_asked", true).apply()
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7044)
            }
        }
    }

    override fun onDestroy() {
        mobile.Detach(this)
        super.onDestroy()
    }

    @Deprecated("Activity result callback used by the platform document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!mobile.ActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}
