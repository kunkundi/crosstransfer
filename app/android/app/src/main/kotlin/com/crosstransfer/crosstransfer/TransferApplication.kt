package com.crosstransfer.crosstransfer

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

// The engine and native core belong to the process, so an Activity recreation
// or dismissal does not destroy FFI callbacks during a foreground transfer.
class TransferApplication : Application() {
    lateinit var engine: FlutterEngine
        private set
    lateinit var mobile: MobileBridge
        private set

    override fun onCreate() {
        super.onCreate()
        engine = FlutterEngine(this)
        mobile = MobileBridge(this, engine.dartExecutor.binaryMessenger)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
    }
}
