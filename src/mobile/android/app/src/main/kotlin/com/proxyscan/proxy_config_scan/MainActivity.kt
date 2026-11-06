package com.proxyscan.proxy_config_scan

import android.content.Intent
import com.proxyscan.proxy_config_scan.system.SystemChannelHandler
import com.proxyscan.proxy_config_scan.vpn.VpnChannelHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var vpnHandler: VpnChannelHandler? = null
    private var systemHandler: SystemChannelHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        vpnHandler = VpnChannelHandler(this, flutterEngine).also { it.attach() }
        systemHandler = SystemChannelHandler(this, flutterEngine).also { it.attach() }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (vpnHandler?.handleActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        systemHandler?.dispose()
        systemHandler = null
        super.onDestroy()
    }
}
