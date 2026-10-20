package com.pcgkolect.pcgkolect_app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var usb: UsbBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usb = UsbBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    // The system starts (or resumes, singleTop) the app when the device is plugged in.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        usb?.onAttachIntent(intent)
    }

    override fun onDestroy() {
        usb?.dispose()
        usb = null
        super.onDestroy()
    }
}
