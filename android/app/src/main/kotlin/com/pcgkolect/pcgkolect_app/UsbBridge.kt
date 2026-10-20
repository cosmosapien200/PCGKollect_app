package com.pcgkolect.pcgkolect_app

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * USB host side of the wired link to the RV1103 (PROTOCOL.md §5). The device exposes a
 * vendor interface (class 0xFF, subclass 0x50) with one bulk OUT and one bulk IN endpoint
 * carrying the same message frames as the ESP32 UART link. This bridge only moves bytes;
 * framing and the request/response logic live in Dart (lib/device/usb_link.dart).
 *
 *   method channel "pcgk/usb": list, open {name}, write {data}, close
 *   event channel  "pcgk/usb/data":   ByteArray chunks from the device, error "USB_CLOSED" at end
 *   event channel  "pcgk/usb/attach": {"event": "attached"|"detached", "name": ...}
 */
class UsbBridge(private val context: Context, messenger: BinaryMessenger) {
    companion object {
        const val SUBCLASS = 0x50
        private const val ACTION_PERMISSION = "com.pcgkolect.USB_PERMISSION"
    }

    private val usb = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())
    private val writer = Executors.newSingleThreadExecutor()
    private var dataSink: EventChannel.EventSink? = null
    private var attachSink: EventChannel.EventSink? = null

    private var conn: UsbDeviceConnection? = null
    private var iface: UsbInterface? = null
    private var epIn: UsbEndpoint? = null
    private var epOut: UsbEndpoint? = null
    private var reader: Thread? = null
    @Volatile private var running = false
    private var pendingOpen: Pair<String, MethodChannel.Result>? = null

    init {
        MethodChannel(messenger, "pcgk/usb").setMethodCallHandler(::onCall)
        EventChannel(messenger, "pcgk/usb/data").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { dataSink = sink }
            override fun onCancel(args: Any?) { dataSink = null }
        })
        EventChannel(messenger, "pcgk/usb/attach").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { attachSink = sink }
            override fun onCancel(args: Any?) { attachSink = null }
        })
        val filter = IntentFilter().apply {
            addAction(ACTION_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
    }

    fun dispose() {
        close()
        try { context.unregisterReceiver(receiver) } catch (_: Exception) {}
        writer.shutdownNow()
    }

    /** Called by MainActivity when the system starts/resumes it for a USB attach. */
    fun onAttachIntent(intent: Intent?) {
        if (intent?.action != UsbManager.ACTION_USB_DEVICE_ATTACHED) return
        val d = intent.parcelableDevice() ?: return
        if (findInterface(d) != null) emitAttach("attached", d.deviceName)
    }

    private fun emitAttach(event: String, name: String) =
        main.post { attachSink?.success(mapOf("event" to event, "name" to name)) }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            when (intent.action) {
                ACTION_PERMISSION -> {
                    val p = pendingOpen ?: return
                    pendingOpen = null
                    val d = usb.deviceList[p.first]
                    if (d != null && usb.hasPermission(d)) doOpen(d, p.second)
                    else p.second.error("USB_PERMISSION", "USB permission was not granted", null)
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    val d = intent.parcelableDevice() ?: return
                    if (findInterface(d) != null) emitAttach("attached", d.deviceName)
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    val d = intent.parcelableDevice() ?: return
                    if (findInterface(d) != null || d.deviceName == openName) {
                        if (d.deviceName == openName) close()
                        emitAttach("detached", d.deviceName)
                    }
                }
            }
        }
    }

    private fun Intent.parcelableDevice(): UsbDevice? =
        if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        else @Suppress("DEPRECATION") getParcelableExtra(UsbManager.EXTRA_DEVICE)

    private var openName: String? = null

    private fun findInterface(d: UsbDevice): UsbInterface? {
        for (i in 0 until d.interfaceCount) {
            val f = d.getInterface(i)
            if (f.interfaceClass == UsbConstants.USB_CLASS_VENDOR_SPEC && f.interfaceSubclass == SUBCLASS) return f
        }
        return null
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> result.success(usb.deviceList.values.filter { findInterface(it) != null }.map {
                mapOf(
                    "name" to it.deviceName,
                    "product" to (it.productName ?: "PCGKolect"),
                    "serial" to (if (usb.hasPermission(it)) it.serialNumber else null),
                    "permission" to usb.hasPermission(it),
                )
            })
            "open" -> {
                val name = call.argument<String>("name")
                val d = usb.deviceList[name]
                if (d == null) {
                    result.error("USB_NOT_FOUND", "The device is not connected", null)
                } else if (usb.hasPermission(d)) {
                    doOpen(d, result)
                } else {
                    pendingOpen = Pair(d.deviceName, result)
                    val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                    val pi = PendingIntent.getBroadcast(
                        context, 0, Intent(ACTION_PERMISSION).setPackage(context.packageName), flags)
                    usb.requestPermission(d, pi)
                }
            }
            "write" -> {
                val data = call.argument<ByteArray>("data")
                val c = conn
                val ep = epOut
                if (data == null || c == null || ep == null) {
                    result.error("USB_CLOSED", "USB link is not open", null)
                    return
                }
                writer.execute {
                    var off = 0
                    var ok = true
                    while (off < data.size) {
                        val n = minOf(16384, data.size - off)
                        val w = c.bulkTransfer(ep, data, off, n, 2000)
                        if (w <= 0) { ok = false; break }
                        off += w
                    }
                    main.post {
                        if (ok) result.success(null) else result.error("USB_WRITE", "USB write failed", null)
                    }
                }
            }
            "close" -> { close(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun doOpen(d: UsbDevice, result: MethodChannel.Result) {
        close()
        val f = findInterface(d)
        val c = usb.openDevice(d)
        if (f == null || c == null) {
            result.error("USB_OPEN", "Cannot open the USB device", null)
            return
        }
        if (!c.claimInterface(f, true)) {
            c.close()
            result.error("USB_OPEN", "Cannot claim the PCGKolect USB interface", null)
            return
        }
        var i: UsbEndpoint? = null
        var o: UsbEndpoint? = null
        for (k in 0 until f.endpointCount) {
            val e = f.getEndpoint(k)
            if (e.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
            if (e.direction == UsbConstants.USB_DIR_IN) i = e else o = e
        }
        if (i == null || o == null) {
            c.releaseInterface(f)
            c.close()
            result.error("USB_OPEN", "Unexpected USB interface layout", null)
            return
        }
        conn = c; iface = f; epIn = i; epOut = o; openName = d.deviceName
        running = true
        val inEp: UsbEndpoint = i
        reader = Thread({
            val buf = ByteArray(16384)
            while (running) {
                val n = c.bulkTransfer(inEp, buf, buf.size, 200)
                if (n > 0) {
                    val chunk = buf.copyOf(n)
                    main.post { dataSink?.success(chunk) }
                }
            }
        }, "pcgk-usb-in").also { it.start() }
        result.success(mapOf("serial" to d.serialNumber, "product" to (d.productName ?: "PCGKolect")))
    }

    fun close() {
        running = false
        reader?.join(500)
        reader = null
        val c = conn
        if (c != null) {
            iface?.let { c.releaseInterface(it) }
            c.close()
            main.post { dataSink?.error("USB_CLOSED", "USB link closed", null) }
        }
        conn = null; iface = null; epIn = null; epOut = null; openName = null
    }
}
