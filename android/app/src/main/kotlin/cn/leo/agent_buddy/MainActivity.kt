package cn.leo.agent_buddy

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var calendarBridge: CalendarBridge? = null
    private var remindersBridge: RemindersBridge? = null
    private var locationBridge: LocationBridge? = null

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
    }
}
