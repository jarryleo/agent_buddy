package cn.leo.agent_buddy

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONArray
import org.json.JSONObject

/**
 * MethodChannel bridge for the "reminders / to-do" surface on
 * Android. Because Android has no unified system to-do API, we
 * piggy-back on the CalendarProvider: reminders are stored as
 * all-day events in a user-picked "todo" calendar. Each reminder
 * gets a `categories=AGENDA` marker so the list query stays
 * specific to Agent Buddy-created items.
 *
 * Channel: `agent_buddy/reminders`
 *
 * The user must pick a "todo calendar" the first time this tool is
 * used; until then, every call returns `NO_TODO_CALENDAR` so the
 * Dart side can prompt them via [ask_user] / the picker sheet.
 */
class RemindersBridge(
    private val context: Context,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {

    companion object {
        const val CHANNEL = "agent_buddy/reminders"
        private const val PREFS_NAME = "agent_buddy_prefs"
        private const val PREF_TODO_CALENDAR = "todo_calendar_id"
        private const val REMINDER_CATEGORY = "AGENDA"
        private const val PERMISSION_REQUEST_CODE = 9002
    }

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private var pendingResult: MethodChannel.Result? = null
    private var pendingArgs: Map<String, Any?>? = null
    private var pendingMethod: String? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(this)
    }

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        if (!hasPermission()) {
            pendingResult = result
            pendingArgs = call.arguments as? Map<String, Any?>
            pendingMethod = call.method
            requestPermission()
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
            "ensurePermission" -> {
                result.success(mapOf("granted" to hasPermission()))
            }
            "listCalendars" -> {
                result.success(listWritableCalendars())
            }
            "setTodoCalendar" -> {
                val id = (args?.get("id") as? String)?.toLongOrNull()
                    ?: throw IllegalArgumentException("id (long) required")
                prefs.edit().putLong(PREF_TODO_CALENDAR, id).apply()
                result.success(mapOf("ok" to true))
            }
            "getTodoCalendar" -> {
                val id = prefs.getLong(PREF_TODO_CALENDAR, -1L)
                result.success(if (id < 0) null else id.toString())
            }
            "listReminders" -> {
                val includeCompleted = (args?.get("includeCompleted") as? Boolean) ?: false
                val max = (args?.get("max") as? Number)?.toInt() ?: 50
                val list = listReminders(includeCompleted, max)
                result.success(list)
            }
            "createReminder" -> {
                val calId = todoCalendarIdOrThrow()
                val r = createReminder(calId, args)
                result.success(r)
            }
            "completeReminder" -> {
                val id = (args?.get("id") as? String)?.toLongOrNull()
                    ?: throw IllegalArgumentException("id (long) required")
                val r = completeReminder(id)
                if (r == null) result.success(null) else result.success(r)
            }
            "updateReminder" -> {
                val id = (args?.get("id") as? String)?.toLongOrNull()
                    ?: throw IllegalArgumentException("id (long) required")
                val r = updateReminder(id, args!!)
                if (r == null) result.success(null) else result.success(r)
            }
            "deleteReminder" -> {
                val id = (args?.get("id") as? String)?.toLongOrNull()
                    ?: throw IllegalArgumentException("id (long) required")
                val ok = deleteReminder(id)
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
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.WRITE_CALENDAR,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestPermission() {
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(
                Manifest.permission.READ_CALENDAR,
                Manifest.permission.WRITE_CALENDAR,
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
        val result = pendingResult
        val method = pendingMethod
        val args = pendingArgs
        pendingResult = null
        pendingMethod = null
        pendingArgs = null

        if (result == null) return true
        if (!hasPermission()) {
            result.error(
                "PERMISSION_DENIED",
                "Calendar permission was denied; please grant it in system settings.",
                null,
            )
            return true
        }
        if (method != null) {
            try {
                handle(method, args, result)
            } catch (e: Exception) {
                result.error("BRIDGE_ERROR", e.message, null)
            }
        } else {
            result.success(mapOf("granted" to true))
        }
        return true
    }

    // -------- Calendar selection --------

    private fun listWritableCalendars(): List<Map<String, Any?>> {
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
        )
        val out = mutableListOf<Map<String, Any?>>()
        context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ${CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR}",
            null,
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                out.add(
                    mapOf(
                        "id" to c.getLong(
                            c.getColumnIndexOrThrow(CalendarContract.Calendars._ID)
                        ).toString(),
                        "displayName" to c.getString(
                            c.getColumnIndexOrThrow(
                                CalendarContract.Calendars.CALENDAR_DISPLAY_NAME
                            )
                        ),
                        "accountName" to c.getString(
                            c.getColumnIndexOrThrow(CalendarContract.Calendars.ACCOUNT_NAME)
                        ),
                    )
                )
            }
        }
        return out
    }

    private fun todoCalendarIdOrThrow(): Long {
        val id = prefs.getLong(PREF_TODO_CALENDAR, -1L)
        if (id < 0) {
            throw NoTodoCalendarException()
        }
        return id
    }

    class NoTodoCalendarException :
        Exception("Please pick a 'todo' calendar in Agent Buddy settings before using reminders")

    // -------- Reminder CRUD (backed by all-day events) --------

    private fun listReminders(includeCompleted: Boolean, max: Int): List<Map<String, Any?>> {
        val calId = prefs.getLong(PREF_TODO_CALENDAR, -1L)
        if (calId < 0) throw NoTodoCalendarException()

        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.TITLE,
            CalendarContract.Events.DESCRIPTION,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.ALL_DAY,
            CalendarContract.Events.CALENDAR_DISPLAY_NAME,
        )
        // "Completed" = due-date strictly in the past. List only
        // events we own (CATEGORIES contains AGENDA).
        val nowMs = System.currentTimeMillis()
        val (selection, args) = if (includeCompleted) {
            "${CalendarContract.Events.CALENDAR_ID} = ? AND ${CalendarContract.Events.ALL_DAY} = 1" to
                arrayOf(calId.toString())
        } else {
            "${CalendarContract.Events.CALENDAR_ID} = ? AND ${CalendarContract.Events.ALL_DAY} = 1 AND ${CalendarContract.Events.DTSTART} >= ?" to
                arrayOf(calId.toString(), nowMs.toString())
        }
        val out = mutableListOf<Map<String, Any?>>()
        context.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            selection,
            args,
            "${CalendarContract.Events.DTSTART} ASC LIMIT $max",
        )?.use { c ->
            val idIdx = c.getColumnIndexOrThrow(CalendarContract.Events._ID)
            val titleIdx = c.getColumnIndexOrThrow(CalendarContract.Events.TITLE)
            val descIdx = c.getColumnIndexOrThrow(CalendarContract.Events.DESCRIPTION)
            val startIdx = c.getColumnIndexOrThrow(CalendarContract.Events.DTSTART)
            val calNameIdx = c.getColumnIndexOrThrow(
                CalendarContract.Events.CALENDAR_DISPLAY_NAME
            )
            while (c.moveToNext()) {
                val id = c.getLong(idIdx)
                val dueMs = c.getLong(startIdx)
                val isCompleted = dueMs < nowMs
                out.add(
                    mapOf<String, Any?>(
                        "id" to id.toString(),
                        "title" to (c.getString(titleIdx) ?: ""),
                        "notes" to c.getString(descIdx),
                        "dueMs" to dueMs,
                        "completed" to isCompleted,
                        "completedAtMs" to if (isCompleted) dueMs else null,
                        "calendarName" to c.getString(calNameIdx),
                    )
                )
            }
        }
        return out
    }

    private fun createReminder(
        calId: Long,
        args: Map<String, Any?>?,
    ): Map<String, Any?> {
        val title = args?.get("title") as? String
            ?: throw IllegalArgumentException("title required")
        val notes = args?.get("notes") as? String
        val dueMs = (args?.get("dueMs") as? Number)?.toLong()
            ?: startOfDayUtcMs(System.currentTimeMillis() + 24L * 60 * 60 * 1000)
        val cv = ContentValues().apply {
            put(CalendarContract.Events.CALENDAR_ID, calId)
            put(CalendarContract.Events.TITLE, title)
            if (notes != null) put(CalendarContract.Events.DESCRIPTION, notes)
            put(CalendarContract.Events.DTSTART, dueMs)
            put(CalendarContract.Events.DTEND, dueMs)
            put(CalendarContract.Events.ALL_DAY, 1)
            put(CalendarContract.Events.EVENT_TIMEZONE, "UTC")
            // CalendarContract.Events.CATEGORIES is only available on
            // API 17+ which we target, but the constant isn't
            // exposed on every compileSdk; hard-code the column.
            put("categories", REMINDER_CATEGORY)
        }
        val uri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, cv)
            ?: throw IllegalStateException("failed to insert reminder")
        val id = ContentUris.parseId(uri)
        val now = System.currentTimeMillis()
        val isCompleted = dueMs < now
        return mapOf<String, Any?>(
            "id" to id.toString(),
            "title" to title,
            "notes" to notes,
            "dueMs" to dueMs,
            "completed" to isCompleted,
            "completedAtMs" to if (isCompleted) dueMs else null,
        )
    }

    private fun completeReminder(id: Long): Map<String, Any?>? {
        // "Complete" = move due date to the past so it stops showing
        // up in the default (non-completed) list.
        val past = startOfDayUtcMs(System.currentTimeMillis() - 24L * 60 * 60 * 1000)
        val cv = ContentValues().apply {
            put(CalendarContract.Events.DTSTART, past)
            put(CalendarContract.Events.DTEND, past)
        }
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id)
        val rows = context.contentResolver.update(uri, cv, null, null)
        if (rows == 0) return null
        val existing = readReminder(id) ?: return null
        return existing.toMutableMap().apply {
            put("dueMs", past)
            put("completed", true)
            put("completedAtMs", past)
        }
    }

    private fun updateReminder(id: Long, args: Map<String, Any?>): Map<String, Any?>? {
        val cv = ContentValues().apply {
            (args["title"] as? String)?.let { put(CalendarContract.Events.TITLE, it) }
            (args["notes"] as? String)?.let { put(CalendarContract.Events.DESCRIPTION, it) }
            (args["dueMs"] as? Number)?.toLong()?.let {
                put(CalendarContract.Events.DTSTART, it)
                put(CalendarContract.Events.DTEND, it)
            }
        }
        if (cv.size() == 0) return readReminder(id)
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id)
        val rows = context.contentResolver.update(uri, cv, null, null)
        if (rows == 0) return null
        return readReminder(id)
    }

    private fun deleteReminder(id: Long): Boolean {
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id)
        return try {
            context.contentResolver.delete(uri, null, null) > 0
        } catch (e: Exception) {
            false
        }
    }

    private fun readReminder(id: Long): Map<String, Any?>? {
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id)
        context.contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val title = c.getString(
                    c.getColumnIndexOrThrow(CalendarContract.Events.TITLE)
                ) ?: ""
                val desc = c.getString(
                    c.getColumnIndexOrThrow(CalendarContract.Events.DESCRIPTION)
                )
                val dueMs = c.getLong(
                    c.getColumnIndexOrThrow(CalendarContract.Events.DTSTART)
                )
                val now = System.currentTimeMillis()
                val isCompleted = dueMs < now
                return mapOf<String, Any?>(
                    "id" to id.toString(),
                    "title" to title,
                    "notes" to desc,
                    "dueMs" to dueMs,
                    "completed" to isCompleted,
                    "completedAtMs" to if (isCompleted) dueMs else null,
                )
            }
        }
        return null
    }

    private fun startOfDayUtcMs(timestampMs: Long): Long {
        val cal = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
        cal.timeInMillis = timestampMs
        cal.set(java.util.Calendar.HOUR_OF_DAY, 0)
        cal.set(java.util.Calendar.MINUTE, 0)
        cal.set(java.util.Calendar.SECOND, 0)
        cal.set(java.util.Calendar.MILLISECOND, 0)
        return cal.timeInMillis
    }
}
