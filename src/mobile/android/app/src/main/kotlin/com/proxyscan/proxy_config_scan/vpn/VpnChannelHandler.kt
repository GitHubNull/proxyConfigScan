package com.proxyscan.proxy_config_scan.vpn

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel `proxy_scan/vpn` + EventChannel `proxy_scan/vpn_events` 桥（设计文档 §3）。
 * start/prepare 需要系统 VPN 授权框：由 Activity.onActivityResult 转发给 [handleActivityResult]。
 */
class VpnChannelHandler(
    private val activity: Activity,
    flutterEngine: FlutterEngine,
) : MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    companion object {
        const val METHOD_CHANNEL = "proxy_scan/vpn"
        const val EVENT_CHANNEL = "proxy_scan/vpn_events"
        private const val REQ_VPN_CONSENT = 0x70a1
    }

    private val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)

    private var pendingResult: MethodChannel.Result? = null
    private var pendingAction: String? = null
    private var pendingStart: Pair<String, Int>? = null

    fun attach() {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> handleStart(call, result)
            "stop" -> {
                ContextCompat.startForegroundService(activity, ProxyVpnService.stopIntent(activity))
                result.success(mapOf("ok" to true))
            }
            "status" -> result.success(VpnEngine.statusSnapshot())
            "prepare" -> handlePrepare(result)
            "isBatteryExempted" -> {
                val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(mapOf("exempted" to pm.isIgnoringBatteryOptimizations(activity.packageName)))
            }
            "requestBatteryExemption" -> {
                val intent = Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${activity.packageName}"),
                )
                if (intent.resolveActivity(activity.packageManager) != null) {
                    activity.startActivity(intent)
                } else {
                    activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                }
                result.success(mapOf("ok" to true))
            }
            "clearError" -> {
                VpnEngine.clearError()
                result.success(mapOf("ok" to true))
            }
            else -> result.notImplemented()
        }
    }

    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        val host = call.argument<String>("host")
        val port = call.argument<Int>("port")
        if (host.isNullOrBlank() || port == null || port !in 1..65535) {
            result.error("INTERNAL", "start 参数不合法（host/port）", null)
            return
        }
        val consent = VpnService.prepare(activity)
        if (consent == null) {
            doStart(result, host, port)
            return
        }
        pendingResult = result
        pendingAction = "start"
        pendingStart = host to port
        activity.startActivityForResult(consent, REQ_VPN_CONSENT)
    }

    private fun handlePrepare(result: MethodChannel.Result) {
        val consent = VpnService.prepare(activity)
        if (consent == null) {
            result.success(mapOf("granted" to true))
            return
        }
        pendingResult = result
        pendingAction = "prepare"
        activity.startActivityForResult(consent, REQ_VPN_CONSENT)
    }

    private fun doStart(result: MethodChannel.Result, host: String, port: Int) {
        ContextCompat.startForegroundService(activity, ProxyVpnService.startIntent(activity, host, port))
        result.success(mapOf("ok" to true))
    }

    /** 由 Activity.onActivityResult 调用；返回 true 表示已消费 */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_VPN_CONSENT) return false
        val result = pendingResult ?: return true
        val action = pendingAction
        val startArgs = pendingStart
        pendingResult = null
        pendingAction = null
        pendingStart = null

        when {
            action == "prepare" -> result.success(mapOf("granted" to (resultCode == Activity.RESULT_OK)))
            resultCode == Activity.RESULT_OK && startArgs != null -> doStart(result, startArgs.first, startArgs.second)
            else -> result.error("USER_DECLINED_CONSENT", "用户拒绝了 VPN 授权", null)
        }
        return true
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        VpnEngine.attachSink(events)
    }

    override fun onCancel(arguments: Any?) {
        VpnEngine.attachSink(null)
    }
}
