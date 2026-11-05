package com.proxyscan.proxy_config_scan.vpn

/**
 * libtun2socks.so 的 JNI 绑定（cpp/tun2socks_jni.c）。
 *
 * native 方法声明为实例方法（JNI 符号 Java_..._vpn_Tun2Socks_run/stop 落在本类上）；
 * C 侧第二参数按 jclass 声明，与 jobject ABI 兼容且未被使用。
 * 错误码与 C 侧 #define 镜像。
 */
class Tun2Socks private constructor() {
    init {
        System.loadLibrary("tun2socks")
    }

    external fun run(
        tunFd: Int,
        mtu: Int,
        netifIp: String,
        netifMask: String,
        socksAddr: String,
        udpgwAddr: String?,
    ): Int

    external fun stop(): Int

    companion object {
        val instance = Tun2Socks()

        const val OK = 0
        const val ERR_ALREADY_RUNNING = -1
        const val ERR_INVALID_ARG = -2
        const val ERR_THREAD_CREATE = -3
        const val ERR_START_TIMEOUT = -4
        const val ERR_INIT_BASE = -10
        const val ERR_INIT_REACTOR = -11
        const val ERR_INIT_SIGNAL = -12
        const val ERR_INIT_TUN = -13
        const val ERR_INIT_ARGS = -14
        const val ERR_INIT_DEVICE = -15
        const val ERR_INIT_UDPGW = -16
        const val ERR_INIT_BUF = -17

        fun errorText(code: Int): String = when (code) {
            ERR_ALREADY_RUNNING -> "tun2socks 已在运行"
            ERR_INVALID_ARG -> "参数不合法"
            ERR_THREAD_CREATE -> "工作线程创建失败"
            ERR_START_TIMEOUT -> "启动超时"
            ERR_INIT_BASE -> "网络全局初始化失败"
            ERR_INIT_REACTOR -> "事件反应堆初始化失败"
            ERR_INIT_SIGNAL -> "信号处理初始化失败"
            ERR_INIT_TUN -> "tun 设备初始化失败"
            ERR_INIT_ARGS -> "地址参数解析失败"
            ERR_INIT_DEVICE -> "设备读通道初始化失败"
            ERR_INIT_UDPGW -> "udpgw 客户端初始化失败"
            ERR_INIT_BUF -> "设备写缓冲分配失败"
            else -> "未知错误($code)"
        }
    }
}
