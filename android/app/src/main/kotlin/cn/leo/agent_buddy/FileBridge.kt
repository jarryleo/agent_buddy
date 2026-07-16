package cn.leo.agent_buddy

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * MethodChannel bridge for the mobile `file` tool.
 *
 * Channel: `agent_buddy/file`
 *
 * File picker (unchanged from previous build):
 *   - pick({mime_type?, read_only?}) -> {id, name, size, mime_type, path}
 *       OR {cancelled: true}.
 *   - release({id}) -> void.
 *   - readPicker({id, max_bytes}) -> Uint8List
 *   - writePicker({id, bytes, append?}) -> void
 *   - readAttrPicker({id}) -> {type, size, modified_ms, ...}
 *
 * Working directory (Android only — SAF tree URI):
 *   - pickTree() -> {path, tree_uri} OR {cancelled: true}.
 *   - writeWorking({rel_path, bytes, append?}) -> void | error
 *   - readWorking({rel_path, max_bytes}) -> Uint8List
 *   - listWorking({rel_path, recursive?}) -> {path, entries: [...]}
 *   - deleteWorking({rel_path, recursive?}) -> void | error
 *   - renameWorking({from, to}) -> void | error
 *   - readAttrWorking({rel_path}) -> {type, size, ...}
 *   - mkdirsWorking({rel_path}) -> void
 *
 *   Every working-dir op transparently re-prompts for the tree
 *   when the existing grant is revoked (e.g. the user cleared
 *   app data in system settings). The Dart caller never sees a
 *   transient auth error; if the user dismisses the re-auth
 *   picker, the op returns `{cancelled: true}`.
 *
 * Permission flow:
 *   The system file picker (`ACTION_OPEN_DOCUMENT`) and the
 *   system folder picker (`ACTION_OPEN_DOCUMENT_TREE`) grant
 *   per-URI access via `FLAG_GRANT_READ_URI_PERMISSION`
 *   (and `FLAG_GRANT_WRITE_URI_PERMISSION` for write), so no
 *   Android runtime permission is required. The tree picker
 *   also takes `FLAG_GRANT_PERSISTABLE_URI_PERMISSION` so the
 *   grant survives an app restart.
 *
 * Concurrency: at most one picker / tree picker visible at a
 * time. Multiple calls while a picker is up are parked in
 * `pendingPicks` / `pendingEnsures` and resumed in order.
 */
class FileBridge(
        private val context: Context,
        private val activity: Activity,
) : MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {

    companion object {
        const val CHANNEL = "agent_buddy/file"
        private const val PICKER_REQUEST_CODE = 9010
        private const val TREE_PICKER_REQUEST_CODE = 9011
        private const val TAG = "FileBridge"
        private const val MAX_ENTRIES = 200

        // SharedPreferences keys mirrored by `StorageService`
        // on the Dart side. The Dart side also mirrors them
        // (so the two layers stay in sync either way).
        private const val PREFS = "agent_buddy_prefs"
        private const val KEY_WORKING_DIR = "model_working_directory"
        private const val KEY_WORKING_TREE = "model_working_tree_uri"

        private const val ENVELOPE_CANCELLED = "cancelled"
    }

    // ---------- Picker state (file picker) ----------

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
    private val pendingPicks: MutableMap<String, PendingPick> = ConcurrentHashMap()
    private val pickSeq: AtomicInteger = AtomicInteger(0)
    @Volatile
    private var activeCallId: String? = null

    // ---------- Tree-picker state (working directory) ----------

    private data class PendingEnsure(
        val onResult: (String?) -> Unit,
        val delivered: AtomicBoolean,
    )

    private val pendingEnsures: MutableMap<String, PendingEnsure> =
        ConcurrentHashMap()
    private val ensureSeq: AtomicInteger = AtomicInteger(0)
    @Volatile
    private var activeEnsure: String? = null

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
            "pickTree" -> handlePickTree(result)
            "writeWorking" -> handleWriteWorking(call, result)
            "readWorking" -> handleReadWorking(call, result)
            "listWorking" -> handleListWorking(call, result)
            "deleteWorking" -> handleDeleteWorking(call, result)
            "renameWorking" -> handleRenameWorking(call, result)
            "readAttrWorking" -> handleReadAttrWorking(call, result)
            "mkdirsWorking" -> handleMkdirsWorking(call, result)
            "ensurePermission" -> {
                result.error(
                    "NOT_SUPPORTED",
                    "ensurePermission is not used by the file tool: " +
                        "ACTION_OPEN_DOCUMENT / ACTION_OPEN_DOCUMENT_TREE " +
                        "grant per-URI access without any Android runtime " +
                        "permission",
                    null,
                )
            }
            else -> result.notImplemented()
        }
    }

    // ---------- File picker (unchanged) ----------

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
        if (activeCallId != null) return
        launchPicker(callId)
    }

    private fun launchPicker(callId: String) {
        val pending = pendingPicks[callId] ?: return
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
            drainPickerQueue()
        }
    }

    private fun drainPickerQueue() {
        val next = pendingPicks.keys.sortedBy { pickSeqOf(it) }.firstOrNull()
        if (next != null) launchPicker(next)
    }

    private fun pickSeqOf(callId: String): Int =
        callId.removePrefix("f-").toIntOrNull() ?: Int.MAX_VALUE

    // ---------- Tree picker (working directory) ----------

    private fun handlePickTree(result: MethodChannel.Result) {
        runEnsure { treeUri ->
            if (treeUri == null) {
                result.success(mapOf(ENVELOPE_CANCELLED to true))
                return@runEnsure
            }
            try {
                val displayPath = treeUriToDisplayPath(Uri.parse(treeUri))
                result.success(
                    mapOf(
                        "path" to displayPath,
                        "tree_uri" to treeUri,
                    ),
                )
            } catch (e: Exception) {
                result.error(
                    "BRIDGE_ERROR",
                    "could not resolve tree URI: ${e.message}",
                    null,
                )
            }
        }
    }

    private fun runEnsure(onResult: (String?) -> Unit) {
        val callId = "e-${ensureSeq.incrementAndGet()}"
        pendingEnsures[callId] = PendingEnsure(
            onResult = onResult,
            delivered = AtomicBoolean(false),
        )
        if (activeEnsure != null) return
        launchTreePicker(callId)
    }

    private fun launchTreePicker(callId: String) {
        val pending = pendingEnsures[callId] ?: return
        activeEnsure = callId

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }
        try {
            activity.startActivityForResult(intent, TREE_PICKER_REQUEST_CODE)
        } catch (e: android.content.ActivityNotFoundException) {
            activeEnsure = null
            pendingEnsures.remove(callId)
            if (pending.delivered.compareAndSet(false, true)) {
                pending.onResult(null)
            }
            drainEnsureQueue()
        }
    }

    private fun drainEnsureQueue() {
        val next = pendingEnsures.keys.sortedBy { ensureSeqOf(it) }.firstOrNull()
        if (next != null) launchTreePicker(next)
    }

    private fun ensureSeqOf(callId: String): Int =
        callId.removePrefix("e-").toIntOrNull() ?: Int.MAX_VALUE

    /**
     * Re-auth wrapper for working-dir ops. The [block] is
     * responsible for calling `result.success(...)` /
     * `result.error(...)` itself; this wrapper only handles
     * the re-prompt flow.
     *
     * Flow:
     *   1. Read the persisted tree URI.
     *   2. If no URI on disk (first-time / cleared data),
     *      launch the picker, then run [block] with the
     *      newly-granted root.
     *   3. If a URI exists, run [block] with the existing
     *      root. If [block] throws [WorkingDirAuthException],
     *      re-prompt the user, then re-run [block] with the
     *      new root.
     *
     * Non-auth errors are surfaced as `result.error` from
     * inside [block] — the wrapper doesn't try to translate
     * them.
     */
    private fun runWithWorkingDirAuth(
        result: MethodChannel.Result,
        block: (DocumentFile) -> Unit,
    ) {
        val initial = readPersistedTreeRoot()
        if (initial == null) {
            runEnsure { newTreeUri ->
                if (newTreeUri == null) {
                    result.success(mapOf(ENVELOPE_CANCELLED to true))
                    return@runEnsure
                }
                val newRoot = rootFor(Uri.parse(newTreeUri))
                if (newRoot == null) {
                    result.error(
                        "PATH_NOT_FOUND",
                        "could not open tree URI after re-pick",
                        null,
                    )
                    return@runEnsure
                }
                runOp(result, block, newRoot)
            }
            return
        }
        try {
            runOp(result, block, initial)
        } catch (e: WorkingDirAuthException) {
            Log.w(TAG, "working-dir grant revoked, re-prompting: ${e.message}")
            runEnsure { newTreeUri ->
                if (newTreeUri == null) {
                    result.success(mapOf(ENVELOPE_CANCELLED to true))
                    return@runEnsure
                }
                val newRoot = rootFor(Uri.parse(newTreeUri))
                if (newRoot == null) {
                    result.error(
                        "PATH_NOT_FOUND",
                        "could not open tree URI after re-pick",
                        null,
                    )
                    return@runEnsure
                }
                runOp(result, block, newRoot)
            }
        }
    }

    private fun runOp(
        result: MethodChannel.Result,
        block: (DocumentFile) -> Unit,
        root: DocumentFile,
    ) {
        try {
            block(root)
        } catch (e: WorkingDirOpException) {
            result.error(e.code, e.message ?: e.code, null)
        } catch (e: Exception) {
            result.error("BRIDGE_ERROR", e.message ?: "unknown", null)
        }
    }

    // ---------- Working-dir ops ----------

    private fun handleWriteWorking(call: MethodCall, result: MethodChannel.Result) {
        val relPath = (call.argument<String>("rel_path") ?: "").trim()
        val bytes = call.argument<ByteArray>("bytes")
        val append = call.argument<Boolean>("append") ?: false
        if (relPath.isEmpty() || bytes == null) {
            result.error("INVALID_ARGUMENT", "rel_path and bytes are required", null)
            return
        }
        runWithWorkingDirAuth(result) { root ->
            writeWorkingFile(root, relPath, bytes, append)
            result.success(null)
        }
    }

    private fun writeWorkingFile(
        root: DocumentFile,
        relPath: String,
        bytes: ByteArray,
        append: Boolean,
    ) {
        val segments = splitRelPath(relPath)
        val parent = ensureParent(root, segments.dropLast(1))
            ?: throw WorkingDirOpException(
                "PATH_NOT_FOUND",
                "parent directory not found for $relPath",
            )
        val name = segments.last()
        val file = parent.findFile(name)
            ?: parent.createFile(guessMimeType(name), name)
            ?: throw WorkingDirOpException(
                "BRIDGE_ERROR",
                "createFile returned null for $name",
            )
        val mode = if (append) "wa" else "wt"
        try {
            (context.contentResolver.openOutputStream(file.uri, mode)
                ?: throw WorkingDirOpException(
                    "BRIDGE_ERROR",
                    "openOutputStream returned null for $name",
                )).use { out ->
                out.write(bytes)
                out.flush()
            }
        } catch (e: SecurityException) {
            throw WorkingDirAuthException("write permission denied: ${e.message}")
        } catch (e: FileNotFoundException) {
            throw WorkingDirAuthException("file URI grant revoked: ${e.message}")
        }
    }

    private fun handleReadWorking(call: MethodCall, result: MethodChannel.Result) {
        val relPath = (call.argument<String>("rel_path") ?: "").trim()
        val maxBytes = (call.argument<Number>("max_bytes"))?.toLong()
            ?: 2L * 1024 * 1024
        if (relPath.isEmpty()) {
            result.error("INVALID_ARGUMENT", "rel_path is required", null)
            return
        }
        runWithWorkingDirAuth(result) { root ->
            val bytes = readWorkingFile(root, relPath, maxBytes)
            result.success(bytes)
        }
    }

    private fun readWorkingFile(
        root: DocumentFile,
        relPath: String,
        maxBytes: Long,
    ): ByteArray {
        val node = resolveChild(root, relPath, createDirs = false)
            ?: throw WorkingDirOpException(
                "PATH_NOT_FOUND",
                "path not found: $relPath",
            )
        if (node.isDirectory) {
            throw WorkingDirOpException(
                "INVALID_ARGUMENT",
                "cannot read a directory: $relPath",
            )
        }
        return try {
            context.contentResolver.openInputStream(node.uri)?.use { input ->
                input.readBytesWithCap(maxBytes)
            } ?: throw WorkingDirOpException(
                "BRIDGE_ERROR",
                "openInputStream returned null for $relPath",
            )
        } catch (e: SecurityException) {
            throw WorkingDirAuthException("read permission denied: ${e.message}")
        } catch (e: FileNotFoundException) {
            throw WorkingDirAuthException("file URI grant revoked: ${e.message}")
        } catch (e: FileTooLargeException) {
            throw WorkingDirOpException("FILE_TOO_LARGE", e.message ?: "too large")
        }
    }

    private fun handleListWorking(call: MethodCall, result: MethodChannel.Result) {
        val relPath = (call.argument<String>("rel_path") ?: "").trim()
        val recursive = call.argument<Boolean>("recursive") ?: false
        if (relPath.isEmpty()) {
            result.error("INVALID_ARGUMENT", "rel_path is required", null)
            return
        }
        runWithWorkingDirAuth(result) { root ->
            val dir = if (relPath.isEmpty()) root
                else resolveChild(root, relPath, createDirs = false)
                    ?: throw WorkingDirOpException(
                        "PATH_NOT_FOUND",
                        "directory not found: $relPath",
                    )
            if (!dir.isDirectory) {
                throw WorkingDirOpException(
                    "INVALID_ARGUMENT",
                    "not a directory: $relPath",
                )
            }
            val entries = mutableListOf<Map<String, Any?>>()
            collectEntries(dir, relPath, recursive, entries, mutableSetOf())
            result.success(
                mapOf(
                    "path" to "working://$relPath",
                    "entries" to entries,
                ),
            )
        }
    }

    private fun collectEntries(
        dir: DocumentFile,
        relDir: String,
        recursive: Boolean,
        out: MutableList<Map<String, Any?>>,
        visited: MutableSet<String>,
    ) {
        if (out.size >= MAX_ENTRIES) return
        val guard = dir.uri.toString()
        if (!visited.add(guard)) return

        for (child in dir.listFiles()) {
            if (out.size >= MAX_ENTRIES) return
            val name = child.name ?: continue
            val childRel =
                if (relDir.isEmpty()) name else "$relDir/$name"
            out.add(
                mapOf(
                    "name" to name,
                    "path" to "working://$childRel",
                    "is_directory" to child.isDirectory,
                    "size" to if (child.isDirectory) 0L else child.length(),
                    "modified_ms" to child.lastModified(),
                ),
            )
            if (recursive && child.isDirectory) {
                collectEntries(child, childRel, recursive, out, visited)
            }
        }
    }

    private fun handleDeleteWorking(call: MethodCall, result: MethodChannel.Result) {
        val relPath = (call.argument<String>("rel_path") ?: "").trim()
        val recursive = call.argument<Boolean>("recursive") ?: false
        if (relPath.isEmpty()) {
            result.error("INVALID_ARGUMENT", "rel_path is required", null)
            return
        }
        runWithWorkingDirAuth(result) { root ->
            val node = resolveChild(root, relPath, createDirs = false)
                ?: throw WorkingDirOpException(
                    "PATH_NOT_FOUND",
                    "path not found: $relPath",
                )
            if (node.isDirectory && !recursive && node.listFiles().isNotEmpty()) {
                throw WorkingDirOpException(
                    "DIRECTORY_NOT_EMPTY",
                    "directory is not empty; set recursive=true to delete",
                )
            }
            try {
                if (!node.delete()) {
                    throw WorkingDirOpException(
                        "BRIDGE_ERROR",
                        "delete returned false for $relPath",
                    )
                }
            } catch (e: SecurityException) {
                throw WorkingDirAuthException("delete permission denied: ${e.message}")
            }
            result.success(null)
        }
    }

    private fun handleRenameWorking(call: MethodCall, result: MethodChannel.Result) {
        val from = (call.argument<String>("from") ?: "").trim()
        val to = (call.argument<String>("to") ?: "").trim()
        if (from.isEmpty() || to.isEmpty()) {
            result.error("INVALID_ARGUMENT", "from and to are required", null)
            return
        }
        runWithWorkingDirAuth(result) { root ->
            val src = resolveChild(root, from, createDirs = false)
                ?: throw WorkingDirOpException(
                    "PATH_NOT_FOUND",
                    "path not found: $from",
                )
            val dst = resolveChild(root, to, createDirs = false)
            if (dst != null) {
                throw WorkingDirOpException(
                    "DESTINATION_EXISTS",
                    "destination already exists: $to",
                )
            }
            val toSegments = splitRelPath(to)
            val dstParent = ensureParent(root, toSegments.dropLast(1))
                ?: throw WorkingDirOpException(
                    "PATH_NOT_FOUND",
                    "destination parent not found: $to",
                )
            val newName = toSegments.last()
            try {
                val renamed = if (sameParent(src.uri, dstParent.uri)) {
                    src.renameTo(newName)
                } else {
                    moveAcrossParents(src, dstParent, newName)
                    true
                }
                if (!renamed) {
                    throw WorkingDirOpException(
                        "BRIDGE_ERROR",
                        "rename returned false for $from -> $to",
                    )
                }
            } catch (e: SecurityException) {
                throw WorkingDirAuthException("rename permission denied: ${e.message}")
            }
            result.success(null)
        }
    }

    private fun sameParent(a: Uri, b: Uri): Boolean {
        val aParent = a.toString().substringBeforeLast('/')
        val bParent = b.toString().substringBeforeLast('/')
        return aParent == bParent
    }

    /**
     * `DocumentFile.renameTo` only renames within the same
     * parent. Cross-parent moves need a copy + delete. We
     * use `dstParent.createFile` / `createDirectory` for the
     * new node, then `ContentResolver` to copy bytes (for
     * files) or recurse for directories.
     */
    private fun moveAcrossParents(
        src: DocumentFile,
        dstParent: DocumentFile,
        newName: String,
    ) {
        if (src.isDirectory) {
            val newDir = dstParent.createDirectory(newName)
                ?: throw WorkingDirOpException(
                    "BRIDGE_ERROR",
                    "createDirectory returned null for $newName",
                )
            for (child in src.listFiles()) {
                val childName = child.name ?: continue
                moveAcrossParents(child, newDir, childName)
            }
            if (!src.delete()) {
                throw WorkingDirOpException(
                    "BRIDGE_ERROR",
                    "delete-after-copy returned false",
                )
            }
        } else {
            val mime = src.type ?: guessMimeType(newName)
            val newFile = dstParent.createFile(mime, newName)
                ?: throw WorkingDirOpException(
                    "BRIDGE_ERROR",
                    "createFile returned null for $newName",
                )
            context.contentResolver.openInputStream(src.uri)?.use { input ->
                context.contentResolver.openOutputStream(newFile.uri, "w")?.use { out ->
                    input.copyTo(out)
                } ?: throw WorkingDirOpException(
                    "BRIDGE_ERROR",
                    "openOutputStream returned null",
                )
            } ?: throw WorkingDirOpException(
                "BRIDGE_ERROR",
                "openInputStream returned null",
            )
            if (!src.delete()) {
                throw WorkingDirOpException(
                    "BRIDGE_ERROR",
                    "delete-after-copy returned false",
                )
            }
        }
    }

    private fun handleReadAttrWorking(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val relPath = (call.argument<String>("rel_path") ?: "").trim()
        if (relPath.isEmpty()) {
            result.error("INVALID_ARGUMENT", "rel_path is required", null)
            return
        }
        runWithWorkingDirAuth(result) { root ->
            val node = resolveChild(root, relPath, createDirs = false)
                ?: throw WorkingDirOpException(
                    "PATH_NOT_FOUND",
                    "path not found: $relPath",
                )
            result.success(
                mapOf(
                    "type" to if (node.isDirectory) "directory" else "file",
                    "size" to if (node.isDirectory) 0L else node.length(),
                    "modified_ms" to node.lastModified(),
                    "accessed_ms" to node.lastModified(),
                    "changed_ms" to node.lastModified(),
                    "is_directory" to node.isDirectory,
                    "is_file" to !node.isDirectory,
                    "is_link" to false,
                ),
            )
        }
    }

    private fun handleMkdirsWorking(call: MethodCall, result: MethodChannel.Result) {
        val relPath = (call.argument<String>("rel_path") ?: "").trim()
        if (relPath.isEmpty()) {
            result.error("INVALID_ARGUMENT", "rel_path is required", null)
            return
        }
        runWithWorkingDirAuth(result) { root ->
            ensureParent(root, splitRelPath(relPath))
            result.success(null)
        }
    }

    // ---------- Tree-URI helpers ----------

    private fun readPersistedTreeRoot(): DocumentFile? {
        val raw = prefs().getString(KEY_WORKING_TREE, null) ?: return null
        return rootFor(Uri.parse(raw))
    }

    private fun rootFor(uri: Uri): DocumentFile? {
        return try {
            DocumentFile.fromTreeUri(context, uri)
        } catch (e: SecurityException) {
            null
        }
    }

    private fun saveWorkingDirectory(treeUri: String, displayPath: String) {
        prefs().edit()
            .putString(KEY_WORKING_TREE, treeUri)
            .putString(KEY_WORKING_DIR, displayPath)
            .apply()
    }

    private fun prefs(): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun treeUriToDisplayPath(uri: Uri): String {
        val docId = try {
            DocumentsContract.getTreeDocumentId(uri)
        } catch (_: Exception) {
            return uri.toString()
        }
        if (!docId.contains(":")) return "/$docId"
        val (vol, rest) = docId.split(":", limit = 2)
        val prefix = when (vol) {
            "primary" -> "/storage/emulated/0"
            else -> "/storage/$vol"
        }
        return "$prefix/${rest.replace("%2F", "/")}"
    }

    // ---------- DocumentFile navigation ----------

    private fun splitRelPath(rel: String): List<String> =
        rel.split('/').filter { it.isNotEmpty() }

    private fun resolveChild(
        root: DocumentFile,
        relPath: String,
        createDirs: Boolean,
    ): DocumentFile? {
        val segments = splitRelPath(relPath)
        if (segments.isEmpty()) return root
        var node: DocumentFile = root
        for (seg in segments) {
            val next = node.findFile(seg)
            if (next != null) {
                node = next
            } else if (createDirs) {
                node = node.createDirectory(seg) ?: return null
            } else {
                return null
            }
        }
        return node
    }

    private fun ensureParent(
        root: DocumentFile,
        segments: List<String>,
    ): DocumentFile? {
        if (segments.isEmpty()) return root
        var node: DocumentFile = root
        for (seg in segments) {
            val next = node.findFile(seg)
            if (next != null) {
                if (!next.isDirectory) return null
                node = next
            } else {
                node = node.createDirectory(seg) ?: return null
            }
        }
        return node
    }

    private fun guessMimeType(name: String): String {
        val ext = name.substringAfterLast('.', missingDelimiterValue = "")
            .lowercase()
        if (ext.isEmpty()) return "application/octet-stream"
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }

    // ---------- Activity result routing ----------

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        return when (requestCode) {
            PICKER_REQUEST_CODE -> handleFilePickerResult(resultCode, data)
            TREE_PICKER_REQUEST_CODE -> handleTreePickerResult(resultCode, data)
            else -> false
        }
    }

    private fun handleFilePickerResult(
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        val callId = activeCallId
        activeCallId = null
        if (callId == null) {
            drainPickerQueue()
            return true
        }
        val pending = pendingPicks.remove(callId)
        if (pending == null) {
            drainPickerQueue()
            return true
        }
        deliverPickResult(callId, pending, resultCode, data)
        drainPickerQueue()
        return true
    }

    private fun handleTreePickerResult(
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        val callId = activeEnsure
        activeEnsure = null
        if (callId == null) {
            drainEnsureQueue()
            return true
        }
        val pending = pendingEnsures.remove(callId)
        if (pending == null) {
            drainEnsureQueue()
            return true
        }
        if (pending.delivered.get()) {
            drainEnsureQueue()
            return true
        }
        val treeUri: Uri? =
            data?.takeIf { resultCode == Activity.RESULT_OK }?.data
        if (treeUri == null) {
            pending.delivered.set(true)
            pending.onResult(null)
            drainEnsureQueue()
            return true
        }
        try {
            val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            context.contentResolver.takePersistableUriPermission(treeUri, flags)
            val displayPath = treeUriToDisplayPath(treeUri)
            saveWorkingDirectory(treeUri.toString(), displayPath)
            pending.delivered.set(true)
            pending.onResult(treeUri.toString())
        } catch (e: SecurityException) {
            Log.w(TAG, "takePersistableUriPermission failed: ${e.message}")
            pending.delivered.set(true)
            pending.onResult(null)
        }
        drainEnsureQueue()
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
            pending.result.success(mapOf(ENVELOPE_CANCELLED to true))
            return
        }
        val uri: Uri? = data.data
        if (uri == null) {
            pending.delivered.set(true)
            pending.result.success(mapOf(ENVELOPE_CANCELLED to true))
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

    // ---------- File picker (release / read / write / readAttr) ----------

    private fun handleRelease(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        if (id.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "id is required", null)
            return
        }
        val picked = pickedById.remove(id)
        if (picked != null) {
            try {
                val resolver = context.contentResolver
                resolver.releasePersistableUriPermission(
                    picked.uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
                resolver.releasePersistableUriPermission(
                    picked.uri,
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            } catch (e: SecurityException) {
                Log.w(TAG, "releasePersistableUriPermission: ${e.message}")
            }
        }
        result.success(null)
    }

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
            val mode = "wt"
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

    // ---------- helpers ----------

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

    private class FileTooLargeException(message: String) : Exception(message)
    private class WorkingDirAuthException(message: String) : Exception(message)
    private class WorkingDirOpException(
        val code: String,
        message: String,
    ) : Exception(message)

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
