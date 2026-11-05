package com.proxyscan.proxy_config_scan.util

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object Logger {
    private const val TAG = "ProxyScan"

    /** ColorOS 等国产 ROM 会拦截 untrusted_app 的 logcat 输出，
     *  引擎关键事件同步落盘到应用私有目录，debug 包可 run-as 读取 */
    @Volatile
    private var logFile: File? = null

    private val tsFormat = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)

    fun initFile(context: Context) {
        logFile = File(context.filesDir, "vpn-engine.log")
    }

    fun d(msg: String) {
        Log.d(TAG, msg)
        append("D", msg)
    }

    fun w(msg: String, t: Throwable? = null) {
        if (t != null) Log.w(TAG, msg, t) else Log.w(TAG, msg)
        append("W", if (t != null) "$msg (${t.javaClass.simpleName}: ${t.message})" else msg)
    }

    fun e(msg: String, t: Throwable? = null) {
        if (t != null) Log.e(TAG, msg, t) else Log.e(TAG, msg)
        append("E", if (t != null) "$msg (${t.javaClass.simpleName}: ${t.message})" else msg)
    }

    @Synchronized
    private fun append(level: String, msg: String) {
        val f = logFile ?: return
        runCatching {
            if (f.length() > 256 * 1024) f.writeText("") // 环形截断
            f.appendText("${tsFormat.format(Date())} $level/$TAG: $msg\n")
        }
    }
}
