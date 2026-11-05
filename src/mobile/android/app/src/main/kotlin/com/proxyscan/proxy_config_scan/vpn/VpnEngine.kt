package com.proxyscan.proxy_config_scan.vpn

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import com.proxyscan.proxy_config_scan.bridge.DnsForwarder
import com.proxyscan.proxy_config_scan.bridge.LocalSocks5Server
import com.proxyscan.proxy_config_scan.util.Logger
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * VPN 转发编排与状态机（doc/vpn-forwarding-design.md §3.3/§7/§10）。
 * 由 [ProxyVpnService] 驱动 start/stop；事件经 [eventSink] 1s 一帧推送。
 */
object VpnEngine {
    enum class State { IDLE, PREPARING, RUNNING, STOPPING, ERROR }

    // Builder / tun2socks 内网参数（设计文档 §2，两侧必须一致）
    private const val TUN_IP = "10.10.10.2"
    private const val TUN_MASK = "255.255.255.0"
    private const val TUN_CIDR = 32
    private const val DNS_SERVER = "223.5.5.5"
    private const val MTU = 1500
    private const val SOCKS_ADDR = "127.0.0.1:10808"
    private const val UDPGW_ADDR = "127.0.0.1:7300"
    private const val SESSION_NAME = "ProxyScan"

    /** 连续 CONNECT 失败达到该阈值且期间零成功 → 判上游不可达（design §3.2 error 帧） */
    private const val UPSTREAM_FAIL_THRESHOLD = 5

    @Volatile
    var state: State = State.IDLE
        private set

    @Volatile
    var upstream: String? = null
        private set

    @Volatile
    var errorCode: String? = null
        private set

    @Volatile
    var errorMessage: String? = null
        private set

    val txBytes = AtomicLong(0)
    val rxBytes = AtomicLong(0)
    val dnsQueries = AtomicLong(0)
    val udpDropped = AtomicLong(0)
    val activeConnections = AtomicInteger(0)

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    private var vpnInterface: ParcelFileDescriptor? = null
    private var tunFd: Int? = null
    private var localBridge: LocalSocks5Server? = null
    private var dnsForwarder: DnsForwarder? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var statsTimer: ScheduledExecutorService? = null
    private var service: ProxyVpnService? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 连续失败计数（本地桥回调）：达阈值且无成功 → error 态 */
    private val consecutiveFailures = AtomicInteger(0)
    @Volatile
    private var sawSuccess = false

    fun attachSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        if (sink != null) pushState()
    }

    /** 在 [service] 内调用：建 tun、起本地桥与 tun2socks、持锁、推 RUNNING */
    fun start(service: ProxyVpnService, host: String, port: Int) {
        if (state == State.RUNNING || state == State.PREPARING) {
            Logger.w("VpnEngine.start 忽略：当前状态 $state")
            return
        }
        this.service = service
        upstream = "$host:$port"
        errorCode = null
        errorMessage = null
        setState(State.PREPARING)

        try {
            Logger.d("VpnEngine.start: 开始建立 tun（上游=$upstream）")
            val pfd = establishTunnel(service)
                ?: return fail("TUN_OPEN_FAILED", "VpnService establish 返回空")
            vpnInterface = pfd
            Logger.d("VpnEngine.start: tun 已建立 fd=${pfd.fd}")

            val protectSocket: (java.net.Socket) -> Boolean = { protectOnMain { service?.protect(it) == true } }
            val protectDatagram: (java.net.DatagramSocket) -> Boolean = { protectOnMain { service?.protect(it) == true } }

            val bridge = LocalSocks5Server(
                upstreamProvider = { upstream?.let { parseUpstream(it) } },
                protect = protectSocket,
                activeConnections = activeConnections,
                onChunk = { bytes, aToB ->
                    if (aToB) txBytes.addAndGet(bytes) else rxBytes.addAndGet(bytes)
                },
                onSuccess = {
                    consecutiveFailures.set(0)
                    sawSuccess = true
                },
                onFailure = { code, detail ->
                    Logger.w("CONNECT 失败[$code]: $detail")
                    // INTERNAL（如 protect 失败）属本机问题，不计入"上游不可达"判定
                    if (code != "INTERNAL") {
                        val n = consecutiveFailures.incrementAndGet()
                        if (!sawSuccess && n >= UPSTREAM_FAIL_THRESHOLD) {
                            fail("UPSTREAM_UNREACHABLE", "连续 $n 次连不上上游 $upstream")
                        }
                    }
                },
            )
            bridge.start()
            localBridge = bridge

            val dns = DnsForwarder(protect = protectDatagram, dnsQueries = dnsQueries, udpDropped = udpDropped)
            dns.start()
            dnsForwarder = dns

            // badvpn BTap(BTAP_INIT_FD) 不接管 fd 归属，须由本方在 stop 后关闭
            val rawFd = pfd.detachFd()
            tunFd = rawFd
            val rc = Tun2Socks.instance.run(rawFd, MTU, TUN_IP, TUN_MASK, SOCKS_ADDR, UDPGW_ADDR)
            if (rc != Tun2Socks.OK) {
                closeTunFd()
                return fail("INTERNAL", "tun2socks 启动失败：${Tun2Socks.errorText(rc)}")
            }

            acquireWakeLock(service)
            consecutiveFailures.set(0)
            sawSuccess = false
            startStatsTimer()
            service.updateNotification("运行中 · 上游 $upstream")
            setState(State.RUNNING)
        } catch (t: Throwable) {
            fail("INTERNAL", "启动异常：${t.message}")
        }
    }

    /** 设计文档 §7 清理顺序 */
    fun stop() {
        if (state == State.IDLE) return
        setState(State.STOPPING)
        stopStatsTimer()

        runCatching { localBridge?.close() }
        localBridge = null

        // 清理路径绝不允许再抛异常（JNI 未链接等场景下二次崩溃会带走整个进程）
        runCatching { Tun2Socks.instance.stop() }.onFailure {
            Logger.w("Tun2Socks.stop 异常: ${it.message}")
        }
        closeTunFd()

        runCatching { vpnInterface?.close() }
        vpnInterface = null

        runCatching { dnsForwarder?.close() }
        dnsForwarder = null

        runCatching { wakeLock?.release() }
        wakeLock = null

        service?.stopForegroundService()
        service = null
        upstream = null
        setState(State.IDLE)
    }

    fun clearError() {
        if (state != State.ERROR) return
        errorCode = null
        errorMessage = null
        setState(State.IDLE)
    }

    fun statusSnapshot(): Map<String, Any?> = mapOf(
        "state" to state.name.lowercase(),
        "upstream" to upstream,
        "error" to errorCode,
    )

    private fun establishTunnel(service: ProxyVpnService): ParcelFileDescriptor? {
        return service.Builder()
            .setSession(SESSION_NAME)
            .setMtu(MTU)
            .addAddress(TUN_IP, TUN_CIDR)
            .addRoute("0.0.0.0", 0)
            .addDnsServer(DNS_SERVER)
            .addDisallowedApplication(service.packageName)
            .establish()
    }

    /**
     * ColorOS 对 VpnService.protect() 做了主线程限制（离主线程调用返回 false
     * 或抛 @UiThread 异常），统一切主线程执行并等结果。
     */
    private fun protectOnMain(block: () -> Boolean): Boolean {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = CountDownLatch(1)
        var ok = false
        mainHandler.post {
            ok = block()
            latch.countDown()
        }
        return try {
            latch.await(3, TimeUnit.SECONDS)
            ok
        } catch (_: InterruptedException) {
            false
        }
    }

    private fun closeTunFd() {
        val fd = tunFd ?: return
        tunFd = null
        runCatching { ParcelFileDescriptor.adoptFd(fd).close() }
    }

    private fun acquireWakeLock(context: Context) {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "proxyscan:vpn").apply {
            setReferenceCounted(false)
            acquire(24L * 60 * 60 * 1000) // 最长 24h，stop 时显式释放
        }
    }

    private fun startStatsTimer() {
        stopStatsTimer()
        statsTimer = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "vpn-stats") }.also { t ->
            t.scheduleAtFixedRate({ pushStats() }, 1, 1, TimeUnit.SECONDS)
        }
    }

    private fun stopStatsTimer() {
        statsTimer?.shutdownNow()
        statsTimer = null
    }

    private fun fail(code: String, message: String) {
        Logger.e("VpnEngine fail[$code]: $message")
        errorCode = code
        errorMessage = message
        // 复用 stop 的清理链路，但保留 error 态
        stopStatsTimer()
        runCatching { localBridge?.close() }
        localBridge = null
        runCatching { Tun2Socks.instance.stop() }
        closeTunFd()
        runCatching { vpnInterface?.close() }
        vpnInterface = null
        runCatching { dnsForwarder?.close() }
        dnsForwarder = null
        runCatching { wakeLock?.release() }
        wakeLock = null
        service?.stopForegroundService()
        service = null
        upstream = null
        setState(State.ERROR)
        eventSink?.success(
            mapOf(
                "type" to "error",
                "code" to code,
                "message" to message,
            ),
        )
    }

    private fun setState(s: State) {
        Logger.d("VpnEngine 状态迁移: ${state.name} → ${s.name}（上游=$upstream）")
        state = s
        pushState()
    }

    private fun pushState() {
        val sink = eventSink ?: return
        sink.success(
            mapOf(
                "type" to "state",
                "state" to state.name.lowercase(),
                "upstream" to upstream,
            ),
        )
    }

    private fun pushStats() {
        val sink = eventSink ?: return
        sink.success(
            mapOf(
                "type" to "stats",
                "txBytes" to txBytes.get(),
                "rxBytes" to rxBytes.get(),
                "activeConnections" to activeConnections.get(),
                "dnsQueries" to dnsQueries.get(),
                "udpDropped" to udpDropped.get(),
            ),
        )
    }

    private fun parseUpstream(value: String): Pair<String, Int>? {
        val idx = value.lastIndexOf(':')
        if (idx <= 0) return null
        val host = value.substring(0, idx)
        val port = value.substring(idx + 1).toIntOrNull() ?: return null
        return host to port
    }

    /** 仅供 [ProxyVpnService.onDestroy] 兜底（用户从通知/系统强杀路径） */
    fun onServiceDestroyed(service: ProxyVpnService) {
        if (this.service === service && state != State.IDLE) {
            stop()
        }
    }
}
