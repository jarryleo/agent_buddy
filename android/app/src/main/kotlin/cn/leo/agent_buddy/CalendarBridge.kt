package cn.leo.agent_buddy

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.CalendarContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * MethodChannel bridge for the phone's system calendar.
 *
 * Implements the 6 methods on the `agent_buddy/calendar` channel:
 *   - ensurePermission
 *   - listEvents
 *   - getEvent
 *   - createEvent
 *   - updateEvent
 *   - deleteEvent
 *
 * The Dart side ([CalendarServiceIo]) dispatches into this. Permission
 * is requested lazily on the first call. While the system dialog is
 * up, every concurrent call is parked in a per-call pending map so
 * the user's tap on the dialog resumes **all** of them — not just the
 * most recent one. This matches the pattern used by [LocationBridge]
 * and avoids the "tool call fails before the user can answer" race
 * when the model fires multiple tool calls in quick succession.
 */
class CalendarBridge(
    private val context: Context,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {

    companion object {
        const val CHANNEL = "agent_buddy/calendar"
        private const val PERMISSION_REQUEST_CODE = 9001
    }

    private data class Pending(
        val result: MethodChannel.Result,
        val method: String,
        val args: Map<String, Any?>?,
        val delivered: AtomicBoolean,
    )

    private val pendingResults: MutableMap<String, Pending> = ConcurrentHashMap()
    private val callSeq: AtomicInteger = AtomicInteger(0)
    private var permissionRequestInFlight: Boolean = false

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(this)
    }

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        // ensurePermission is a pure read — return synchronously so
        // the AI can decide whether to invoke the other actions.
        if (call.method == "ensurePermission") {
            result.success(mapOf("granted" to hasPermission()))
            return
        }
        if (!hasPermission()) {
            // Permanent denial short-circuit: don't pop a system
            // dialog the user has already said no to, just fail the
            // call with PERMANENTLY_DENIED so the AI can surface a
            // "open settings" hint.
            if (currentStatus() == "permanently_denied") {
                result.error(
                    "PERMANENTLY_DENIED",
                    "Calendar permission permanently denied; open system settings to enable it",
                    null,
                )
                return
            }
            // Park this call. The user's answer to the system dialog
            // will resume every parked call via
            // onRequestPermissionsResult.
            val callId = nextCallId()
            pendingResults[callId] = Pending(
                result = result,
                method = call.method,
                args = call.arguments as? Map<String, Any?>,
                delivered = AtomicBoolean(false),
            )
            requestPermissionIfNeeded()
            return
        }
        try {
            handle(call.method, call.arguments as? Map<String, Any?>, result)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        } catch (e: Exception) {
            result.error("BRIDGE_ERROR", e.message, null)
        }
    }

    private fun handle(
        method: String,
        args: Map<String, Any?>?,
        result: MethodChannel.Result,
    ) {
        when (method) {
            "listEvents" -> {
                val fromMs = (args?.get("fromMs") as? Number)?.toLong()
                    ?: throw IllegalArgumentException("fromMs required")
                val toMs = (args?.get("toMs") as? Number)?.toLong()
                    ?: throw IllegalArgumentException("toMs required")
                val max = (args?.get("max") as? Number)?.toInt() ?: 50
                val list = listEvents(fromMs, toMs, max)
                result.success(list)
            }
            "getEvent" -> {
                val id = (args?.get("id") as? String)?.toLongOrNull()
                    ?: throw IllegalArgumentException("id (long) required")
                val ev = getEvent(id)
                if (ev == null) {
                    result.success(null)
                } else {
                    result.success(ev)
                }
            }
            "createEvent" -> {
                val ev = createEvent(args)
                result.success(ev)
            }
            "updateEvent" -> {
                val id = (args?.get("id") as? String)?.toLongOrNull()
                    ?: throw IllegalArgumentException("id (long) required")
                val ev = updateEvent(id, args!!)
                if (ev == null) result.success(null) else result.success(ev)
            }
            "deleteEvent" -> {
                val id = (args?.get("id") as? String)?.toLongOrNull()
                    ?: throw IllegalArgumentException("id (long) required")
                val ok = deleteEvent(id)
                result.success(mapOf("ok" to ok))
            }
            else -> result.notImplemented()
        }
    }

    // -------- Permission --------

    private fun hasPermission(): Boolean {
        val read = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.READ_CALENDAR,
        ) == PackageManager.PERMISSION_GRANTED
        if (!read) return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.WRITE_CALENDAR,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    /**
     * Returns one of `granted` / `denied` / `permanently_denied`.
     * "Permanently denied" is detected by a "Don't ask again" tap on
     * the system dialog: the OS stops showing the prompt and
     * `shouldShowRequestPermissionRationale` flips to false, while a
     * one-time decline leaves it true.
     */
    private fun currentStatus(): String {
        if (hasPermission()) return "granted"
        val prefs = context.getSharedPreferences(
            "agent_buddy_prefs",
            Context.MODE_PRIVATE,
        )
        val everAsked = prefs.getBoolean("calendar_permission_requested", false)
        val rationaleOff = !ActivityCompat.shouldShowRequestPermissionRationale(
            activity,
            Manifest.permission.READ_CALENDAR,
        )
        return if (everAsked && rationaleOff) "permanently_denied" else "denied"
    }

    private fun markPermissionRequested() {
        context.getSharedPreferences("agent_buddy_prefs", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("calendar_permission_requested", true)
            .apply()
    }

    private fun requestPermissionIfNeeded() {
        if (permissionRequestInFlight) return
        permissionRequestInFlight = true
        markPermissionRequested()
        val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            arrayOf(
                Manifest.permission.READ_CALENDAR,
                Manifest.permission.WRITE_CALENDAR,
            )
        } else {
            arrayOf(Manifest.permission.READ_CALENDAR)
        }
        ActivityCompat.requestPermissions(activity, perms, PERMISSION_REQUEST_CODE)
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
            val code = if (currentStatus() == "permanently_denied") {
                "PERMANENTLY_DENIED"
            } else {
                "PERMISSION_DENIED"
            }
            val msg = "Calendar permission was denied; please grant it in system settings."
            for ((_, p) in snapshot) {
                if (p.delivered.compareAndSet(false, true)) {
                    p.result.error(code, msg, null)
                }
            }
            return true
        }
        // Re-dispatch every parked call now that permission is granted.
        for ((_, p) in snapshot) {
            if (!p.delivered.compareAndSet(false, true)) continue
            try {
                handle(p.method, p.args, p.result)
            } catch (e: Exception) {
                p.result.error("BRIDGE_ERROR", e.message, null)
            }
        }
        return true
    }

    private fun nextCallId(): String = "cal-${callSeq.incrementAndGet()}"

    // -------- CRUD --------

    private fun listEvents(fromMs: Long, toMs: Long, max: Int): List<Map<String, Any?>> {
        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.CALENDAR_ID,
            CalendarContract.Events.TITLE,
            CalendarContract.Events.DESCRIPTION,
            CalendarContract.Events.EVENT_LOCATION,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND,
            CalendarContract.Events.ALL_DAY,
            CalendarContract.Events.CALENDAR_DISPLAY_NAME,
            CalendarContract.Events.HAS_ALARM,
        )
        val selection =
            "${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ?"
        val selArgs = arrayOf(fromMs.toString(), toMs.toString())
        val sort = "${CalendarContract.Events.DTSTART} ASC LIMIT $max"

        val out = mutableListOf<Map<String, Any?>>()
        context.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            selection,
            selArgs,
            sort,
        )?.use { c ->
            val idIdx = c.getColumnIndexOrThrow(CalendarContract.Events._ID)
            val calIdIdx = c.getColumnIndexOrThrow(CalendarContract.Events.CALENDAR_ID)
            val titleIdx = c.getColumnIndexOrThrow(CalendarContract.Events.TITLE)
            val descIdx = c.getColumnIndexOrThrow(CalendarContract.Events.DESCRIPTION)
            val locIdx = c.getColumnIndexOrThrow(CalendarContract.Events.EVENT_LOCATION)
            val startIdx = c.getColumnIndexOrThrow(CalendarContract.Events.DTSTART)
            val endIdx = c.getColumnIndexOrThrow(CalendarContract.Events.DTEND)
            val allDayIdx = c.getColumnIndexOrThrow(CalendarContract.Events.ALL_DAY)
            val calNameIdx = c.getColumnIndexOrThrow(
                CalendarContract.Events.CALENDAR_DISPLAY_NAME
            )
            val alarmIdx = c.getColumnIndexOrThrow(CalendarContract.Events.HAS_ALARM)
            while (c.moveToNext()) {
                val id = c.getLong(idIdx)
                out.add(
                    mapOf(
                        "id" to id.toString(),
                        "title" to (c.getString(titleIdx) ?: ""),
                        "startMs" to c.getLong(startIdx),
                        "endMs" to if (c.isNull(endIdx)) null else c.getLong(endIdx),
                        "allDay" to (c.getInt(allDayIdx) == 1),
                        "location" to c.getString(locIdx),
                        "notes" to c.getString(descIdx),
                        "calendarId" to c.getLong(calIdIdx).toString(),
                        "calendarName" to c.getString(calNameIdx),
                        "alarmMinutes" to if (c.getInt(alarmIdx) == 1) 15 else null,
                    )
                )
            }
        }
        return out
    }

    private fun getEvent(id: Long): Map<String, Any?>? {
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id)
        context.contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                return rowToMap(c)
            }
        }
        return null
    }

    private fun rowToMap(c: android.database.Cursor): Map<String, Any?> {
        val id = c.getLong(c.getColumnIndexOrThrow(CalendarContract.Events._ID))
        val calId = c.getLong(c.getColumnIndexOrThrow(CalendarContract.Events.CALENDAR_ID))
        return mapOf(
            "id" to id.toString(),
            "title" to (c.getString(c.getColumnIndexOrThrow(CalendarContract.Events.TITLE)) ?: ""),
            "startMs" to c.getLong(c.getColumnIndexOrThrow(CalendarContract.Events.DTSTART)),
            "endMs" to if (c.isNull(c.getColumnIndexOrThrow(CalendarContract.Events.DTEND))) {
                null
            } else {
                c.getLong(c.getColumnIndexOrThrow(CalendarContract.Events.DTEND))
            },
            "allDay" to (c.getInt(c.getColumnIndexOrThrow(CalendarContract.Events.ALL_DAY)) == 1),
            "location" to c.getString(c.getColumnIndexOrThrow(CalendarContract.Events.EVENT_LOCATION)),
            "notes" to c.getString(c.getColumnIndexOrThrow(CalendarContract.Events.DESCRIPTION)),
            "calendarId" to calId.toString(),
            "calendarName" to c.getString(
                c.getColumnIndexOrThrow(CalendarContract.Events.CALENDAR_DISPLAY_NAME)
            ),
            "alarmMinutes" to if (
                c.getInt(c.getColumnIndexOrThrow(CalendarContract.Events.HAS_ALARM)) == 1
            ) 15 else null,
        )
    }

    private fun createEvent(args: Map<String, Any?>?): Map<String, Any?> {
        val title = args?.get("title") as? String
            ?: throw IllegalArgumentException("title required")
        val startMs = (args["startMs"] as? Number)?.toLong()
            ?: throw IllegalArgumentException("startMs required")
        val endMs = (args["end_ms"] as? Number)?.toLong()
            ?: (args["endMs"] as? Number)?.toLong()
        val notes = args?.get("notes") as? String
        val location = args?.get("location") as? String
        val alarmMinutes = (args?.get("alarm_minutes") as? Number)?.toInt()
            ?: (args?.get("alarmMinutes") as? Number)?.toInt()

        val cv = ContentValues().apply {
            put(CalendarContract.Events.DTSTART, startMs)
            if (endMs != null) put(CalendarContract.Events.DTEND, endMs)
            put(CalendarContract.Events.TITLE, title)
            if (notes != null) put(CalendarContract.Events.DESCRIPTION, notes)
            if (location != null) put(CalendarContract.Events.EVENT_LOCATION, location)
            put(CalendarContract.Events.CALENDAR_ID, primaryCalendarId())
            put(CalendarContract.Events.EVENT_TIMEZONE, java.util.TimeZone.getDefault().id)
        }
        val uri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, cv)
            ?: throw IllegalStateException("failed to insert event")
        val id = ContentUris.parseId(uri)
        if (alarmMinutes != null) addAlarm(id, alarmMinutes)
        return getEvent(id) ?: mapOf("id" to id.toString())
    }

    private fun updateEvent(id: Long, args: Map<String, Any?>): Map<String, Any?>? {
        val cv = ContentValues().apply {
            (args["title"] as? String)?.let { put(CalendarContract.Events.TITLE, it) }
            (args["startMs"] as? Number)?.toLong()?.let {
                put(CalendarContract.Events.DTSTART, it)
            }
            (args["end_ms"] as? Number)?.toLong()?.let {
                put(CalendarContract.Events.DTEND, it)
            }
                ?: (args["endMs"] as? Number)?.toLong()?.let {
                    put(CalendarContract.Events.DTEND, it)
                }
            (args["notes"] as? String)?.let { put(CalendarContract.Events.DESCRIPTION, it) }
            (args["location"] as? String)?.let { put(CalendarContract.Events.EVENT_LOCATION, it) }
        }
        if (cv.size() == 0) return getEvent(id)
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id)
        val rows = context.contentResolver.update(uri, cv, null, null)
        if (rows == 0) return null
        (args["alarm_minutes"] as? Number)?.toInt()?.let { replaceAlarm(id, it) }
            ?: (args["alarmMinutes"] as? Number)?.toInt()?.let { replaceAlarm(id, it) }
        return getEvent(id)
    }

    private fun deleteEvent(id: Long): Boolean {
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id)
        return try {
            context.contentResolver.delete(uri, null, null) > 0
        } catch (e: Exception) {
            false
        }
    }

    private fun addAlarm(eventId: Long, minutes: Int) {
        val cv = ContentValues().apply {
            put(CalendarContract.Reminders.MINUTES, minutes)
            put(CalendarContract.Reminders.EVENT_ID, eventId)
            put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
        }
        context.contentResolver.insert(CalendarContract.Reminders.CONTENT_URI, cv)
    }

    private fun replaceAlarm(eventId: Long, minutes: Int) {
        val rUri = CalendarContract.Reminders.CONTENT_URI
        context.contentResolver.delete(
            rUri,
            "${CalendarContract.Reminders.EVENT_ID} = ?",
            arrayOf(eventId.toString()),
        )
        addAlarm(eventId, minutes)
    }

    private fun primaryCalendarId(): Long {
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.IS_PRIMARY,
        )
        context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            null,
            null,
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getInt(c.getColumnIndexOrThrow(CalendarContract.Calendars.IS_PRIMARY)) == 1) {
                    return c.getLong(c.getColumnIndexOrThrow(CalendarContract.Calendars._ID))
                }
            }
            if (c.moveToFirst()) {
                return c.getLong(c.getColumnIndexOrThrow(CalendarContract.Calendars._ID))
            }
        }
        throw IllegalStateException(
            "no writable calendar account on this device; please add a local calendar first",
        )
    }
}
