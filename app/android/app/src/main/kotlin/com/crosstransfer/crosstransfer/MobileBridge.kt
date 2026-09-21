package com.crosstransfer.crosstransfer

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.google.zxing.client.android.Intents
import com.journeyapps.barcodescanner.ScanOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class MobileBridge(private val app: TransferApplication, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.crosstransfer/mobile")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var activity = WeakReference<Activity>(null)
    private var pending: MethodChannel.Result? = null
    private var pending_code: Int? = null
    private var export_source: File? = null
    private var transfer_active = false
    private var io_count = 0
    private var expired = false
    private var service_started = false
    private val cancel_epoch = AtomicInteger()
    private val imported get() = File(app.filesDir, "Imported")
    private val inbox get() = File(app.filesDir, "Inbox")

    init { channel.setMethodCallHandler(::Handle) }

    fun Attach(value: Activity) { activity = WeakReference(value) }
    fun Detach(value: Activity) { if (activity.get() === value) activity.clear() }
    fun Foreground() {
        expired = false
        UpdateService()
        channel.invokeMethod("InboxChanged", null)
    }

    fun BackgroundExpired() {
        expired = true
        cancel_epoch.incrementAndGet()
        service_started = false
        app.stopService(Intent(app, TransferService::class.java))
        channel.invokeMethod("BackgroundExpired", null)
    }

    private fun UpdateService() {
        val needed = (transfer_active || io_count > 0) && !expired
        if (needed == service_started) return
        val intent = Intent(app, TransferService::class.java)
        if (needed) {
            try {
                if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(intent) else app.startService(intent)
                service_started = true
            } catch (_: RuntimeException) {
                // Android may reject a background launch or an exhausted quota.
                // Pause the core instead of claiming it can continue in background.
                BackgroundExpired()
            }
        } else {
            app.stopService(intent)
            service_started = false
        }
    }

    private fun Handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "SetTransferActive" -> { transfer_active = call.arguments == true; UpdateService(); result.success(null) }
                "ScanCode" -> {
                    val options = ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                        .setBeepEnabled(false).setOrientationLocked(false)
                        .setPrompt(call.argument<String>("title").orEmpty())
                        .setCaptureActivity(QrCaptureActivity::class.java)
                    Launch(options.createScanIntent(app), SCAN, result)
                }
                "CancelScan" -> {
                    if (pending_code == SCAN) {
                        activity.get()?.finishActivity(SCAN)
                        // Keep the pending request until onActivityResult so a
                        // late cancellation cannot complete a newly opened scan.
                    }
                    result.success(null)
                }
                "ReadInbox" -> Work(result, active = false) { ReadInbox() }
                "AcknowledgeInbox" -> {
                    val id = UUID.fromString(call.arguments as String).toString()
                    File(inbox, "$id.json").delete()
                    result.success(null)
                }
                "PickFiles", "PickFolder" -> {
                    val folder = call.method == "PickFolder"
                    val intent = Intent(if (folder) Intent.ACTION_OPEN_DOCUMENT_TREE else Intent.ACTION_OPEN_DOCUMENT)
                    if (!folder) { intent.type = "*/*"; intent.addCategory(Intent.CATEGORY_OPENABLE); intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true) }
                    Launch(intent, if (folder) PICK_FOLDER else PICK_FILES, result)
                }
                "ExportDirectory" -> {
                    val source = File(call.arguments as String).canonicalFile
                    require(source.isDirectory && source.path.startsWith(app.dataDir.canonicalPath + File.separator))
                    if (pending != null) error("Another document picker is open")
                    export_source = source
                    Launch(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), EXPORT, result)
                }
                "ShareLink" -> {
                    val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, call.arguments as String)
                    RequireActivity().startActivity(Intent.createChooser(intent, null))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { result.error("mobile", error.message, null) }
    }

    private fun RequireActivity(): Activity = activity.get() ?: error("Open CrossTransfer to continue")
    private fun Launch(intent: Intent, code: Int, result: MethodChannel.Result) {
        check(pending == null) { "Another platform action is open" }
        RequireActivity().startActivityForResult(intent, code)
        pending = result
        pending_code = code
    }

    fun ActivityResult(code: Int, status: Int, data: Intent?): Boolean {
        if (code !in setOf(PICK_FILES, PICK_FOLDER, EXPORT, SCAN)) return false
        if (pending_code != code) return true
        val result = pending
        pending = null
        pending_code = null
        val source = export_source
        export_source = null
        if (result == null) return true
        if (code == SCAN) {
            if (data?.getBooleanExtra(Intents.Scan.MISSING_CAMERA_PERMISSION, false) == true) result.error("camera", "Camera permission denied", null)
            else result.success(if (status == Activity.RESULT_OK) data?.getStringExtra(Intents.Scan.RESULT) else null)
            return true
        }
        if (status != Activity.RESULT_OK || data == null) { result.success(null); return true }
        val epoch = cancel_epoch.get()
        when (code) {
            EXPORT -> Work(result) {
                val tree = data.data ?: error("No destination selected")
                val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                val root = source ?: error("No export source")
                val destination = DocumentsContract.createDocument(app.contentResolver, parent, DocumentsContract.Document.MIME_TYPE_DIR, "CrossTransfer-" + UUID.randomUUID().toString().take(8)) ?: error("Cannot create export directory")
                // Export into a fresh directory, never overwrite existing documents.
                try { Export(root, destination, epoch) }
                catch (error: Exception) {
                    runCatching { DocumentsContract.deleteDocument(app.contentResolver, destination) }
                    throw error
                }
                destination.toString()
            }
            else -> Work(result) { Import(Uris(data), code == PICK_FOLDER, null, epoch) }
        }
        return true
    }

    fun ImportIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return
        try {
            val uris = Uris(intent)
            val content = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString().orEmpty()
            // Avoid re-importing this launch intent after an Activity recreation.
            activity.get()?.intent = Intent(app, MainActivity::class.java).setAction(Intent.ACTION_MAIN)
            val epoch = cancel_epoch.get()
            Work(null, notify = true) { Import(uris, false, content, epoch) }
        } catch (error: Exception) { channel.invokeMethod("ImportError", error.message ?: "Import failed") }
    }

    @Suppress("DEPRECATION")
    private fun Uris(intent: Intent): List<Uri> {
        val values = mutableListOf<Uri>()
        intent.data?.let { values.add(it) }
        intent.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { values.add(it) } }
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { values.addAll(it) }
        else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { values.add(it) }
        return values.distinct().onEach {
            require(it.scheme == "content" && it.authority?.startsWith(app.packageName) != true) { "Unsupported shared file URI" }
        }
    }

    private fun Work(result: MethodChannel.Result?, active: Boolean = true, notify: Boolean = false, action: () -> Any?) {
        if (active) { io_count++; UpdateService() }
        worker.execute {
            try {
                val value = action()
                main.post {
                    result?.success(value)
                    if (notify) channel.invokeMethod("InboxChanged", null)
                }
            } catch (error: Exception) {
                main.post {
                    if (result != null) result.error("files", error.message, null)
                    else channel.invokeMethod("ImportError", error.message ?: "Import failed")
                }
            } finally {
                if (active) main.post { io_count--; UpdateService() }
            }
        }
    }

    private fun ReadInbox(): List<Map<String, Any>> = inbox.listFiles().orEmpty().filter { it.extension == "json" }.sortedBy { it.name }.map { file ->
        val id = UUID.fromString(file.nameWithoutExtension).toString()
        val json = JSONObject(file.readText())
        val names = json.getJSONArray("files")
        val root = File(imported, id).canonicalFile
        val paths = (0 until names.length()).map { i ->
            val target = File(root, names.getString(i)).canonicalFile
            require(target.path.startsWith(root.path + File.separator) && target.exists())
            target.path
        }
        mapOf("id" to id, "paths" to paths, "content" to json.optString("content"))
    }

    private fun SafeName(name: String?, fallback: String): String {
        val value = name.orEmpty().replace('/', '_').replace('\\', '_').replace('\u0000', '_')
        return if (value.isBlank() || value == "." || value == "..") fallback else value
    }

    private fun UniqueName(parent: File, name: String): String {
        var value = name
        var suffix = 1
        while (File(parent, value).exists()) { value = "$suffix-$name"; suffix++ }
        return value
    }

    private fun DisplayName(uri: Uri): String? = app.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
        if (it.moveToFirst()) it.getString(0) else null
    }

    private fun Import(uris: List<Uri>, tree: Boolean, content: String?, epoch: Int): List<String> {
        require(uris.isNotEmpty() || !content.isNullOrBlank()) { "Nothing to import" }
        val id = UUID.randomUUID().toString()
        val root = File(imported, id)
        check(root.mkdirs()) { "Cannot create import directory" }
        val names = mutableListOf<String>()
        try {
            val count = AtomicInteger()
            uris.forEachIndexed { index, uri ->
                val document = if (tree) DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri)) else uri
                val name = UniqueName(root, SafeName(DisplayName(document), "item-$index"))
                val target = File(root, name)
                if (tree) CopyTree(document, target, epoch, count, 0)
                else CopyUri(document, target, epoch)
                names.add(name)
            }
            if (content != null) {
                inbox.mkdirs()
                val temp = File(inbox, "$id.tmp")
                temp.writeText(JSONObject().put("files", JSONArray(names)).put("content", content).toString())
                check(temp.renameTo(File(inbox, "$id.json"))) { "Cannot commit shared files" }
            }
            return names.map { File(root, it).path }
        } catch (error: Exception) { root.deleteRecursively(); throw error }
    }

    private fun CopyTree(uri: Uri, target: File, epoch: Int, count: AtomicInteger, depth: Int) {
        require(depth < 64 && count.incrementAndGet() <= 65535) { "Directory is too large or deeply nested" }
        check(target.mkdirs()) { "Cannot create imported folder" }
        val child_uri = DocumentsContract.buildChildDocumentsUriUsingTree(uri, DocumentsContract.getDocumentId(uri))
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE)
        val cursor = app.contentResolver.query(child_uri, columns, null, null, null) ?: error("Cannot read folder")
        cursor.use {
            var index = 0
            while (it.moveToNext()) {
                val name = UniqueName(target, SafeName(it.getString(1), "item-$index"))
                val child = DocumentsContract.buildDocumentUriUsingTree(uri, it.getString(0))
                val file = File(target, name)
                if (it.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) CopyTree(child, file, epoch, count, depth + 1)
                else {
                    require(count.incrementAndGet() <= 65535) { "Too many files" }
                    CopyUri(child, file, epoch)
                }
                index++
            }
        }
    }

    private fun CopyUri(uri: Uri, target: File, epoch: Int) {
        val input = app.contentResolver.openInputStream(uri) ?: error("Cannot open document")
        input.use { source ->
            check(target.createNewFile()) { "Imported file already exists" }
            target.outputStream().use { Copy(source, it, epoch) }
        }
    }

    private fun Copy(input: InputStream, output: OutputStream, epoch: Int) {
        val buffer = ByteArray(65536)
        while (true) {
            check(cancel_epoch.get() == epoch) { "Background file operation expired" }
            val length = input.read(buffer)
            if (length < 0) break
            output.write(buffer, 0, length)
        }
    }

    private fun Export(source: File, destination: Uri, epoch: Int) {
        source.listFiles()?.forEach { file ->
            require(file.canonicalPath.startsWith(source.canonicalPath + File.separator)) { "Invalid export path" }
            val type = if (file.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream"
            val child = DocumentsContract.createDocument(app.contentResolver, destination, type, file.name) ?: error("Cannot create exported document")
            if (file.isDirectory) Export(file, child, epoch)
            else file.inputStream().use { input ->
                val output = app.contentResolver.openOutputStream(child, "w") ?: error("Cannot open destination")
                output.use { Copy(input, it, epoch) }
            }
        } ?: error("Cannot read export directory")
    }

    companion object {
        private const val PICK_FILES = 7011
        private const val PICK_FOLDER = 7012
        private const val EXPORT = 7013
        private const val SCAN = 7014
    }
}
