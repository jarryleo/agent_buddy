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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * MethodChannel bridge for the "reminders / to-do" surface on
 * Android. Because Android has no unified system to-do API, we
 * piggy-back on the CalendarProvider: reminders are stored as
 * all-day events in a user-picked "todo" calendar. Each reminder
 * gets a marker prefix on its description so the list query stays
 * specific to Agent Buddy-created items.
 *
 * Channel: `agent_buddy/reminders`
 *
 * The user must pick a "todo calendar" the first time this tool is
 * used; until then, every call returns `NO_TODO_CALENDAR` so the
 * Dart side can prompt them via the picker sheet.
 *
 * Permission flow mirrors [CalendarBridge] / [LocationBridge]:
 * concurrent tool calls are all parked in a per-call pending map so
 * the user's tap on the system dialog resumes every one of them.
 *
 * Why a description-prefix marker instead of `categories`:
 * `CalendarContract.Events.CATEGORIES` is part of the contract but
 * several OEM calendar providers (notably Huawei / Xiaomi local
 * calendars) don't expose the column at all, so writing
 * `put("categories", ...)` blows up with
 * `IllegalArgumentException: column 'categories' is invalid`. The
 * `DESCRIPTION` column is universal, so we encode ownership as a
 * short sentinel prefix and strip it on read.
 */
class RemindersBridge(
    private val context: Context,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {

    companion object {
        const val CHANNEL = "agent_buddy/reminders"
        private const val PREFS_NAME = "agent_buddy_prefs"
        private const val PREF_TODO_CALENDAR = "todo_calendar_id"
        private const val PERMISSION_REQUEST_CODE = 9002

        // Description prefix that marks an all-day event as an
        // Agent Buddy reminder. The trailing `|` is a separator so
        // the marker's length is well-defined when we strip it. The
        // SQLite LIKE wildcard `%` is appended in the SELECT
        // so `LIKE '__ab_agenda__|%'` only matches events we own.
        private const val MARKER = "__ab_agenda__|"
    }

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

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
        if (call.method == "ensurePermission") {
            result.success(mapOf("granted" to hasPermission()))
            return
        }
        // Calendar listing & todo-calendar selection never need the
        // runtime permission — they only need the system to know
        // about the user's calendars. Pass them through directly.
        if (call.method == "listCalendars" ||
            call.method == "setTodoCalendar" ||
            call.method == "getTodoCalendar"
        ) {
            try {
                handle(call.method, call.arguments as? Map<String, Any?>, result)
            } catch (e: Exception) {
                result.error("BRIDGE_ERROR", e.message, null)
            }
            return
        }
        if (!hasPermission()) {
            if (currentStatus() == "permanently_denied") {
                result.error(
                    "PERMANENTLY_DENIED",
                    "Calendar permission permanently denied; open system settings to enable it",
                    null,
                )
                return
            }
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

    private fun currentStatus(): String {
        if (hasPermission()) return "granted"
        val rationaleOff = !ActivityCompat.shouldShowRequestPermissionRationale(
            activity,
            Manifest.permission.READ_CALENDAR,
        )
        return if (rationaleOff && hasEverRequested()) "permanently_denied" else "denied"
    }

    private fun hasEverRequested(): Boolean =
        prefs.getBoolean("reminders_permission_requested", false)

    private fun markPermissionRequested() {
        prefs.edit().putBoolean("reminders_permission_requested", true).apply()
    }

    private fun requestPermissionIfNeeded() {
        if (permissionRequestInFlight) return
        permissionRequestInFlight = true
        markPermissionRequested()
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

    private fun nextCallId(): String = "rem-${callSeq.incrementAndGet()}"

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
        // events we own (description starts with the marker).
        val nowMs = System.currentTimeMillis()
        val (selection, args) = if (includeCompleted) {
            "${CalendarContract.Events.CALENDAR_ID} = ? " +
                "AND ${CalendarContract.Events.ALL_DAY} = 1 " +
                "AND ${CalendarContract.Events.DESCRIPTION} LIKE ?" to
                arrayOf(calId.toString(), "$MARKER%")
        } else {
            "${CalendarContract.Events.CALENDAR_ID} = ? " +
                "AND ${CalendarContract.Events.ALL_DAY} = 1 " +
                "AND ${CalendarContract.Events.DTSTART} >= ? " +
                "AND ${CalendarContract.Events.DESCRIPTION} LIKE ?" to
                arrayOf(calId.toString(), nowMs.toString(), "$MARKER%")
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
                        "notes" to stripMarker(c.getString(descIdx)),
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
            // Prepend the marker so the row is identifiable as an
            // Agent Buddy reminder. We can't rely on the
            // `categories` column — some OEM providers (Huawei /
            // Xiaomi local calendars) reject it with
            // `IllegalArgumentException: column 'categories' is
            // invalid`.
            put(CalendarContract.Events.DESCRIPTION, prependMarker(notes))
            put(CalendarContract.Events.DTSTART, dueMs)
            put(CalendarContract.Events.DTEND, dueMs)
            put(CalendarContract.Events.ALL_DAY, 1)
            put(CalendarContract.Events.EVENT_TIMEZONE, "UTC")
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
            (args["notes"] as? String)?.let {
                put(CalendarContract.Events.DESCRIPTION, prependMarker(it))
            }
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
                    "notes" to stripMarker(desc),
                    "dueMs" to dueMs,
                    "completed" to isCompleted,
                    "completedAtMs" to if (isCompleted) dueMs else null,
                )
            }
        }
        return null
    }

    // -------- Marker helpers --------

    private fun prependMarker(notes: String?): String =
        if (notes.isNullOrEmpty()) MARKER else "$MARKER$notes"

    private fun stripMarker(desc: String?): String? {
        if (desc.isNullOrEmpty()) return desc
        return if (desc.startsWith(MARKER)) desc.substring(MARKER.length) else desc
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
