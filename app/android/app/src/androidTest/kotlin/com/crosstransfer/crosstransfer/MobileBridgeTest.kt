package com.crosstransfer.crosstransfer

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.content.IntentFilter
import android.content.BroadcastReceiver
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.client.android.Intents
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class MobileBridgeTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val app get() = instrumentation.targetContext.applicationContext as TransferApplication
    private val id = UUID.randomUUID().toString()
    private val tree get() = DocumentsContract.buildTreeDocumentUri("ct.android.tests.documents", id)
    private lateinit var activity: Activity
    private val imported = mutableListOf<File>()

    private fun Fixture(method: String) {
        val complete = CountDownLatch(1)
        var result = 0
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) { result = resultCode; complete.countDown() }
        }
        val intent = Intent().setClassName(instrumentation.context.packageName, FixtureSetup::class.java.name)
            .putExtra("id", id).putExtra("method", method).putExtra("package", app.packageName)
        app.sendOrderedBroadcast(intent, null, receiver, null, 0, null, null)
        assertTrue("Fixture provider timed out", complete.await(10, TimeUnit.SECONDS))
        assertEquals(Activity.RESULT_OK, result)
    }

    @Before fun Start() {
        if (Build.VERSION.SDK_INT >= 33) {
            ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand("pm grant ${app.packageName} android.permission.POST_NOTIFICATIONS")).use { it.readBytes() }
        }
        // The provider runs under the test APK UID and grants only its generated
        // fixture trees. The production app receives normal temporary URI grants.
        Fixture("ct.setup")
        activity = instrumentation.startActivitySync(Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        instrumentation.waitForIdleSync()
    }

    @After fun Stop() {
        if (::activity.isInitialized) instrumentation.runOnMainSync { activity.finish() }
        imported.forEach { it.deleteRecursively() }
        Fixture("ct.cleanup")
    }

    private class Result : MethodChannel.Result {
        val ready = CountDownLatch(1)
        var value: Any? = null
        var failure: String? = null
        override fun success(result: Any?) { value = result; ready.countDown() }
        override fun error(code: String, message: String?, details: Any?) { failure = "$code: $message"; ready.countDown() }
        override fun notImplemented() { failure = "not implemented"; ready.countDown() }
        fun Await(): Any? {
            assertTrue("Bridge result timed out", ready.await(15, TimeUnit.SECONDS))
            assertNull(failure, failure)
            return value
        }
    }
    private fun Request(method: String, args: Any? = null): Result {
        val result = Result()
        val handle = MobileBridge::class.java.getDeclaredMethod("Handle", MethodCall::class.java, MethodChannel.Result::class.java).apply { isAccessible = true }
        instrumentation.runOnMainSync { handle.invoke(app.mobile, MethodCall(method, args), result) }
        return result
    }
    private fun Picker(method: String, uri: Uri, args: Any? = null): Any? {
        val action = if (method == "PickFiles") Intent.ACTION_OPEN_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT_TREE
        val filter = IntentFilter(action).apply { if (method == "PickFiles") { addCategory(Intent.CATEGORY_OPENABLE); addDataType("*/*") } }
        val monitor = instrumentation.addMonitor(filter, Instrumentation.ActivityResult(Activity.RESULT_OK, Intent().setData(uri)), true)
        try { return Request(method, args).Await() }
        finally { instrumentation.removeMonitor(monitor) }
    }

    @Test fun FolderImportAndExportPreserveContents() {
        val payload = ByteArray(130001) { (it % 251).toByte() }
        val sourceTree = DocumentsContract.buildTreeDocumentUri("ct.android.tests.documents", "$id/输入")
        val paths = Picker("PickFolder", sourceTree) as List<*>
        val copy = File(paths.single() as String)
        imported.add(copy.parentFile!!)
        assertArrayEquals(payload, File(copy, "子目录/中文.bin").readBytes())
        assertTrue(File(copy, "子目录/empty").isDirectory)
        assertEquals(0L, File(copy, "zero.bin").length())
        // A received directory uses the same export path contract as this import.
        val exported = Uri.parse(Picker("ExportDirectory", tree, copy.path) as String)
        val destination = DocumentsContract.getDocumentId(exported)
        val data = DocumentsContract.buildDocumentUriUsingTree(tree, "$destination/子目录/中文.bin")
        assertArrayEquals(payload, app.contentResolver.openInputStream(data)!!.use { it.readBytes() })
        val zero = DocumentsContract.buildDocumentUriUsingTree(tree, "$destination/zero.bin")
        assertArrayEquals(byteArrayOf(), app.contentResolver.openInputStream(zero)!!.use { it.readBytes() })
        val empty = DocumentsContract.buildChildDocumentsUriUsingTree(tree, "$destination/子目录/empty")
        app.contentResolver.query(empty, null, null, null, null)!!.use { assertEquals(0, it.count) }
        // Source provider deletion must not invalidate the persisted POSIX copy.
        DocumentsContract.deleteDocument(app.contentResolver, DocumentsContract.buildDocumentUriUsingTree(sourceTree, "$id/输入"))
        assertArrayEquals(payload, File(copy, "子目录/中文.bin").readBytes())
    }

    @Test fun SharedBatchKeepsDuplicateNamesAndAcknowledgesManifest() {
        val uris = arrayListOf<Uri>()
        for (name in listOf("one", "two")) {
            uris.add(DocumentsContract.buildDocumentUriUsingTree(tree, "$id/$name/same.bin"))
        }
        val intent = Intent(Intent.ACTION_SEND_MULTIPLE).setType("application/octet-stream").putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        instrumentation.runOnMainSync { app.mobile.ImportIntent(intent) }
        @Suppress("UNCHECKED_CAST")
        val items = Request("ReadInbox").Await() as List<Map<String, Any>>
        val item = items.single { entry -> (entry["paths"] as List<*>).size == 2 }
        val paths = (item["paths"] as List<*>).map { File(it as String) }
        imported.add(paths.first().parentFile!!)
        assertEquals(setOf("one", "two"), paths.map { it.readText() }.toSet())
        assertEquals(2, paths.map { it.name }.toSet().size)
        Request("AcknowledgeInbox", item["id"]).Await()
        assertFalse(File(app.filesDir, "Inbox/${item["id"]}.json").exists())
        assertTrue(paths.all { it.exists() })
    }

    @Test fun QrDecoderAndBridgeReturnExactLink() {
        val link = "crosstransfer://r/MXT3XF8SK2"
        val matrix = QRCodeWriter().encode(link, BarcodeFormat.QR_CODE, 256, 256)
        val pixels = IntArray(256 * 256) { i -> if (matrix.get(i % 256, i / 256)) 0xff000000.toInt() else 0xffffffff.toInt() }
        val bitmap = BinaryBitmap(HybridBinarizer(RGBLuminanceSource(256, 256, pixels)))
        val decoded = QRCodeReader().decode(bitmap).text
        assertEquals(link, decoded)
        val monitor = instrumentation.addMonitor(IntentFilter(Intents.Scan.ACTION),
            Instrumentation.ActivityResult(Activity.RESULT_OK, Intent().putExtra(Intents.Scan.RESULT, decoded)), true)
        try { assertEquals(link, Request("ScanCode", mapOf("title" to "Scan QR code")).Await()) }
        finally { instrumentation.removeMonitor(monitor) }
    }

    @Test fun QrCancellationAndPermissionFailureCompleteRequest() {
        for (permission in listOf(false, true)) {
            val data = Intent().putExtra(Intents.Scan.MISSING_CAMERA_PERMISSION, permission)
            val monitor = instrumentation.addMonitor(IntentFilter(Intents.Scan.ACTION),
                Instrumentation.ActivityResult(Activity.RESULT_CANCELED, data), true)
            try {
                val result = Request("ScanCode", mapOf("title" to "Scan QR code"))
                if (permission) {
                    assertTrue(result.ready.await(15, TimeUnit.SECONDS))
                    assertTrue(result.failure.orEmpty().startsWith("camera:"))
                } else assertNull(result.Await())
            } finally { instrumentation.removeMonitor(monitor) }
        }
    }
}
