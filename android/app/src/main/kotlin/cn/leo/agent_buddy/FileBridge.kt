package cn.leo.agent_buddy

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * MethodChannel bridge for the mobile `file` tool.
 *
 * Channel: `agent_buddy/file`
 *
 * Methods:
 *   - pick({mime_type?, read_only?}) -> {id, name, size, mime_type, path}
 *       OR {cancelled: true} when the user backs out.
 *       The call is **parked** until the SAF picker resolves;
 *       never returns a transient error before the user has had
 *       a chance to answer. Cancels are surfaced as a soft
 *       payload, not an exception, so the model can pivot.
 *   - release({id}) -> void. Drops the in-memory mapping +
 *       `releasePersistableUriPermission` for the underlying URI.
 *   - readPicker({id, max_bytes}) -> Uint8List
 *   - writePicker({id, bytes, append?}) -> void
 *   - readAttrPicker({id}) -> {type, size, modified_ms, ...}
 *
 * Permission flow:
 *   **No Android runtime permission is required for the picker.**
 *   The system file picker (`Intent.ACTION_OPEN_DOCUMENT`) grants
 *   per-URI access via `Intent.FLAG_GRANT_READ_URI_PERMISSION`
 *   (and `FLAG_GRANT_WRITE_URI_PERMISSION` for write), so the
 *   app only ever touches the URIs the user explicitly chose.
 *   Persistable URI permission is *not* taken automatically —
 *   the picked URI lives only as long as the OS-granted grant
 *   does, and the model is expected to `release` it when done.
 *   This is intentional: it bounds the app's reach to what the
 *   user just allowed, no more, no less.
 *
 *   The `ensurePermission` legacy entry is intentionally **not**
 *   implemented: the SAF picker is its own permission grant,
 *   there is nothing to check outside of a pick. We surface a
 *   `NOT_SUPPORTED` error so any caller that does probe the
 *   pattern gets a clear answer.
 *
 * Concurrency: at most one picker visible at a time. Multiple
 * pick() calls while a picker is up are parked in
 * [pendingPicks] and resumed in order. Mirrors the
 * permission-park pattern used by LocationBridge / CalendarBridge.
 */
class FileBridge(
    private val context: Context,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {

    companion object {
        const val CHANNEL = "agent_buddy/file"
        private const val PICKER_REQUEST_CODE = 9010
        private const val TAG = "FileBridge"
    }

    private data class Picked(
        val uri: Uri,
        val displayName: String,
        val size: Long,
        val mimeType: String?,
    )

    private data class PendingPick(
        val result: MethodChannel.Result,
        val mimeType: String?,
        val readOnly: Boolean,
        val delivered: AtomicBoolean,
    )

    private val pickedById: MutableMap<String, Picked> = ConcurrentHashMap()
    // Pending pick requests, keyed by a synthetic call id. The
    // call id is also reused as the picked-file id (when the
    // picker resolves successfully) so the caller never has to
    // map one to the other.
    private val pendingPicks: MutableMap<String, PendingPick> = ConcurrentHashMap()
    private val pickSeq: AtomicInteger = AtomicInteger(0)
    // The call id of the pick currently visible on screen, if
    // any. `null` when no picker is up.
    @Volatile
    private var activeCallId: String? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "pick" -> handlePick(call, result)
            "release" -> handleRelease(call, result)
            "readPicker" -> handleReadPicker(call, result)
            "writePicker" -> handleWritePicker(call, result)
            "readAttrPicker" -> handleReadAttrPicker(call, result)
            "ensurePermission" -> {
                // SAF picker is its own grant; nothing to check
                // outside of pick(). Surface a clear NOT_SUPPORTED
                // so probes don't go through silently.
                result.error(
                    "NOT_SUPPORTED",
                    "ensurePermission is not used by the file tool: " +
                        "ACTION_OPEN_DOCUMENT grants per-URI access without any " +
                        "Android runtime permission",
                    null,
                )
            }
            else -> result.notImplemented()
        }
    }

    // -------- pick --------

    private fun handlePick(call: MethodCall, result: MethodChannel.Result) {
        val mimeType = (call.argument<String?>("mime_type"))?.takeIf { it.isNotBlank() }
        val readOnly = call.argument<Boolean>("read_only") ?: false

        val callId = "f-${pickSeq.incrementAndGet()}"
        pendingPicks[callId] = PendingPick(
            result = result,
            mimeType = mimeType,
            readOnly = readOnly,
            delivered = AtomicBoolean(false),
        )
        if (activeCallId != null) {
            // A picker is already up; queue behind it. The id is
            // already reserved so a later `readPicker(id)` won't
            // collide — the entry just doesn't have a real file
            // until its picker resolves.
            return
        }
        launchPicker(callId)
    }

    private fun launchPicker(callId: String) {
        val pending = pendingPicks[callId]
        if (pending == null) return
        activeCallId = callId

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = pending.mimeType ?: "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (!pending.readOnly) {
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false)
            }
        }

        try {
            activity.startActivityForResult(intent, PICKER_REQUEST_CODE)
        } catch (e: android.content.ActivityNotFoundException) {
            activeCallId = null
            pendingPicks.remove(callId)
            if (pending.delivered.compareAndSet(false, true)) {
                pending.result.error(
                    "NOT_SUPPORTED",
                    "no file picker available on this device",
                    null,
                )
            }
            // Continue with the next queued pick (if any) so a
            // single bad device doesn't strand the queue.
            drainQueue()
        }
    }

    private fun drainQueue() {
        // Pick the first still-pending entry (insertion order
        // via the map's iteration is guaranteed on most JVMs but
        // not contractually — find the lowest seq instead).
        val next = pendingPicks.keys.sortedBy { pickSeqOf(it) }.firstOrNull()
        if (next != null) {
            launchPicker(next)
        }
    }

    private fun pickSeqOf(callId: String): Int {
        // callId format: "f-<seq>". Strip the prefix and parse.
        return callId.removePrefix("f-").toIntOrNull() ?: Int.MAX_VALUE
    }

    /**
     * Hooked from [MainActivity.onActivityResult]. Returns
     * `true` for our [PICKER_REQUEST_CODE] so the activity
     * knows we consumed the result.
     */
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        if (requestCode != PICKER_REQUEST_CODE) return false
        val callId = activeCallId
        activeCallId = null
        if (callId == null) {
            drainQueue()
            return true
        }
        val pending = pendingPicks.remove(callId)
        if (pending == null) {
            drainQueue()
            return true
        }
        deliverPickResult(callId, pending, resultCode, data)
        drainQueue()
        return true
    }

    private fun deliverPickResult(
        callId: String,
        pending: PendingPick,
        resultCode: Int,
        data: Intent?,
    ) {
        if (pending.delivered.get()) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.delivered.set(true)
            pending.result.success(mapOf("cancelled" to true))
            return
        }
        val uri: Uri? = data.data
        if (uri == null) {
            pending.delivered.set(true)
            pending.result.success(mapOf("cancelled" to true))
            return
        }
        try {
            val (name, size) = queryDisplayNameAndSize(uri)
            val mime = context.contentResolver.getType(uri)
            pickedById[callId] = Picked(uri, name, size, mime)
            pending.delivered.set(true)
            pending.result.success(
                mapOf(
                    "id" to callId,
                    "name" to name,
                    "size" to size,
                    "mime_type" to mime,
                    "path" to "picker://$callId",
                ),
            )
        } catch (e: SecurityException) {
            pending.delivered.set(true)
            pending.result.error(
                "PICKER_DENIED",
                "the system did not grant access to the picked file: ${e.message}",
                null,
            )
        } catch (e: Exception) {
            pending.delivered.set(true)
            pending.result.error("BRIDGE_ERROR", e.message ?: "unknown", null)
        }
    }

    private fun queryDisplayNameAndSize(uri: Uri): Pair<String, Long> {
        var name = uri.lastPathSegment ?: "file"
        var size = -1L
        val cursor: Cursor? = context.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )
        cursor?.use {
            if (it.moveToFirst()) {
                val nameIdx = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIdx = it.getColumnIndex(OpenableColumns.SIZE)
                if (nameIdx >= 0 && !it.isNull(nameIdx)) {
                    name = it.getString(nameIdx) ?: name
                }
                if (sizeIdx >= 0 && !it.isNull(sizeIdx)) {
                    size = it.getLong(sizeIdx)
                }
            }
        }
        return name to size
    }

    // -------- release --------

    private fun handleRelease(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        if (id.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "id is required", null)
            return
        }
        val picked = pickedById.remove(id)
        if (picked != null) {
            try {
                context.contentResolver.releasePersistableUriPermission(picked.uri)
            } catch (e: SecurityException) {
                // Best-effort; we still drop the in-memory handle.
                Log.w(TAG, "releasePersistableUriPermission: ${e.message}")
            }
        }
        result.success(null)
    }

    // -------- readPicker --------

    private fun handleReadPicker(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val maxBytes = (call.argument<Number>("max_bytes"))?.toLong() ?: 2L * 1024 * 1024
        if (id.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "id is required", null)
            return
        }
        val picked = pickedById[id]
        if (picked == null) {
            result.error(
                "PATH_NOT_FOUND",
                "picker id not found or already released: $id",
                null,
            )
            return
        }
        try {
            val bytes = context.contentResolver.openInputStream(picked.uri)?.use { input ->
                input.readBytesWithCap(maxBytes)
            } ?: throw IllegalStateException("openInputStream returned null")
            result.success(bytes)
        } catch (e: SecurityException) {
            result.error(
                "PICKER_DENIED",
                "access to the picked file was revoked; pick again: ${e.message}",
                null,
            )
        } catch (e: FileTooLargeException) {
            result.error("FILE_TOO_LARGE", e.message, null)
        } catch (e: Exception) {
            result.error("BRIDGE_ERROR", e.message ?: "unknown", null)
        }
    }

    // -------- writePicker --------

    private fun handleWritePicker(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val bytes = call.argument<ByteArray>("bytes")
        if (id.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "id is required", null)
            return
        }
        if (bytes == null) {
            result.error("INVALID_ARGUMENT", "bytes is required", null)
            return
        }
        val picked = pickedById[id]
        if (picked == null) {
            result.error(
                "PATH_NOT_FOUND",
                "picker id not found or already released: $id",
                null,
            )
            return
        }
        try {
            val mode = "wt" // SAF picker URIs are written with "wt"
            context.contentResolver.openOutputStream(picked.uri, mode)?.use { out ->
                out.write(bytes)
                out.flush()
            } ?: throw IllegalStateException("openOutputStream returned null")
            result.success(null)
        } catch (e: SecurityException) {
            result.error(
                "PICKER_DENIED",
                "write access to the picked file was revoked: ${e.message}",
                null,
            )
        } catch (e: Exception) {
            result.error("BRIDGE_ERROR", e.message ?: "unknown", null)
        }
    }

    // -------- readAttrPicker --------

    private fun handleReadAttrPicker(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        if (id.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "id is required", null)
            return
        }
        val picked = pickedById[id]
        if (picked == null) {
            result.error(
                "PATH_NOT_FOUND",
                "picker id not found or already released: $id",
                null,
            )
            return
        }
        try {
            result.success(
                mapOf(
                    "type" to "file",
                    "size" to picked.size,
                    "modified_ms" to System.currentTimeMillis(),
                    "accessed_ms" to System.currentTimeMillis(),
                    "changed_ms" to System.currentTimeMillis(),
                    "is_directory" to false,
                    "is_file" to true,
                    "is_link" to false,
                ),
            )
        } catch (e: Exception) {
            result.error("BRIDGE_ERROR", e.message ?: "unknown", null)
        }
    }

    // -------- helpers --------

    private class FileTooLargeException(message: String) : Exception(message)

    private fun java.io.InputStream.readBytesWithCap(maxBytes: Long): ByteArray {
        val buf = ByteArrayOutputStream()
        val chunk = ByteArray(8 * 1024)
        var total = 0L
        while (true) {
            val n = read(chunk)
            if (n <= 0) break
            total += n
            if (total > maxBytes) {
                throw FileTooLargeException(
                    "file exceeds max_bytes=$maxBytes; raise the limit if you really need it",
                )
            }
            buf.write(chunk, 0, n)
        }
        return buf.toByteArray()
    }
}
