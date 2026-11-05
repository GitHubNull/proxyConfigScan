package com.proxyscan.proxy_config_scan.vpn

import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import com.proxyscan.proxy_config_scan.util.Logger

/**
 * VPN 服务壳：前台服务（specialUse FGS）+ 把生命周期转交 [VpnEngine]。
 * 启动须先经 VpnService.prepare() 授权（VpnChannelHandler 负责弹框）。
 */
class ProxyVpnService : VpnService() {
    companion object {
        const val ACTION_START = "com.proxyscan.vpn.START"
        const val ACTION_STOP = "com.proxyscan.vpn.STOP"
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"

        fun startIntent(context: Context, host: String, port: Int): Intent =
            Intent(context, ProxyVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_HOST, host)
                putExtra(EXTRA_PORT, port)
            }

        fun stopIntent(context: Context): Intent =
            Intent(context, ProxyVpnService::class.java).apply { action = ACTION_STOP }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val host = intent.getStringExtra(EXTRA_HOST) ?: return START_NOT_STICKY
                val port = intent.getIntExtra(EXTRA_PORT, 0)
                if (port <= 0) return START_NOT_STICKY
                goForeground("正在启动代理转发…")
                VpnEngine.start(this, host, port)
            }
            ACTION_STOP -> {
                VpnEngine.stop()
            }
            else -> Logger.w("ProxyVpnService 收到未知 action: ${intent?.action}")
        }
        return START_STICKY
    }

    private fun goForeground(content: String) {
        val notification = NotificationHelper.build(this, content)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                NotificationHelper.NOTIFICATION_ID,
                notification,
                NotificationHelper.foregroundServiceType(),
            )
        } else {
            startForeground(NotificationHelper.NOTIFICATION_ID, notification)
        }
    }

    fun updateNotification(content: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        nm.notify(NotificationHelper.NOTIFICATION_ID, NotificationHelper.build(this, content))
    }

    fun stopForegroundService() {
        if (Build.VERSION.SDK_INT >= 33) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    override fun onDestroy() {
        VpnEngine.onServiceDestroyed(this)
        super.onDestroy()
    }

    override fun onBind(intent: Intent): IBinder? = super.onBind(intent)
}
