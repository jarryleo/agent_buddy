package cn.leo.agent_buddy

import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var calendarBridge: CalendarBridge? = null
    private var remindersBridge: RemindersBridge? = null
    private var locationBridge: LocationBridge? = null
    private var fileBridge: FileBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        calendarBridge = CalendarBridge(applicationContext, this).also {
            it.register(flutterEngine)
        }
        remindersBridge = RemindersBridge(applicationContext, this).also {
            it.register(flutterEngine)
        }
        locationBridge = LocationBridge(applicationContext, this).also {
            it.register(flutterEngine)
        }
        fileBridge = FileBridge(applicationContext, this).also {
            it.register(flutterEngine)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        calendarBridge?.onRequestPermissionsResult(requestCode, permissions, grantResults)
        remindersBridge?.onRequestPermissionsResult(requestCode, permissions, grantResults)
        locationBridge?.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // The file bridge does not request any Android runtime
        // permissions (SAF picker is its own grant), so we
        // intentionally do not forward permission results to it.
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        // Forward to the file bridge so the parked pick() call
        // can resume. The bridge returns true if it consumed
        // the result; we ignore the return value either way so
        // any future plugin that also needs activity results
        // (e.g. file_picker) can co-exist.
        fileBridge?.onActivityResult(requestCode, resultCode, data)
    }
}
