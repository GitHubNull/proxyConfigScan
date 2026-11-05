package com.proxyscan.proxy_config_scan.util

import android.util.Log

object Logger {
    private const val TAG = "ProxyScan"

    fun d(msg: String) = Log.d(TAG, msg)
    fun w(msg: String, t: Throwable? = null) = if (t != null) Log.w(TAG, msg, t) else Log.w(TAG, msg)
    fun e(msg: String, t: Throwable? = null) = if (t != null) Log.e(TAG, msg, t) else Log.e(TAG, msg)
}
