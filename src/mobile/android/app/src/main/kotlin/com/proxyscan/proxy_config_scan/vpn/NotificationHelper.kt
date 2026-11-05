package com.proxyscan.proxy_config_scan.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import com.proxyscan.proxy_config_scan.R

/**
 * VPN 前台服务通知（低重要性 channel，内容显示"运行中 · 上游 host:port"）。
 * startForeground 的 FGS 类型包装：API 34+ 必须显式声明 specialUse。
 */
object NotificationHelper {
    const val CHANNEL_ID = "vpn_service"
    const val NOTIFICATION_ID = 1

    fun ensureChannel(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "VPN 转发服务",
            NotificationManager.IMPORTANCE_LOW,
        ).apply { description = "代理转发运行状态" }
        nm.createNotificationChannel(channel)
    }

    fun build(context: Context, content: String): Notification {
        ensureChannel(context)
        val builder = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("抓包代理配置")
            .setContentText(content)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
        return builder.build()
    }

    fun foregroundServiceType(): Int = if (Build.VERSION.SDK_INT >= 34) {
        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
    } else {
        0
    }
}
