package com.proxyscan.proxy_config_scan.bridge

import com.proxyscan.proxy_config_scan.util.Logger
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket

/**
 * 向 Burp 上游发 HTTP CONNECT 并建立隧道（doc/vpn-forwarding-design.md §4 条款）：
 * 1. CONNECT 请求仅含 Host 头；
 * 2. 严格解析响应头至 \r\n\r\n，状态码必须 2xx；
 * 3. 非 2xx：响应整体原样透传给应用侧后关闭；
 * 4. 逐字节解析头，200 后无残余丢失问题（读端不越过边界）；
 * 5. 连接与握手超时 10s → [TunnelException] code=UPSTREAM_UNREACHABLE；
 *   非 2xx/RST → code=TUNNEL_HANDSHAKE_FAILED。
 */
object HttpConnectTunnel {
    const val TIMEOUT_MS = 10_000
    private const val HEADER_LIMIT = 64 * 1024
    private const val DRAIN_TIMEOUT_MS = 5_000

    class TunnelException(val code: String, message: String, cause: Throwable? = null) :
        IOException(message, cause)

    /**
     * 建立隧道。返回已完成握手（读到 2xx + 空行）的上游 socket，可直接进入 relay。
     * 失败时已按条款处理（非 2xx 已透传），抛 [TunnelException]。
     */
    fun establish(
        appSocket: Socket,
        upstreamHost: String,
        upstreamPort: Int,
        targetHost: String,
        targetPort: Int,
        protect: (Socket) -> Boolean,
    ): Socket {
        val upstream = Socket()
        try {
            // protect 是防回环的第二道保险；第一道 addDisallowedApplication(self) 已保证
            // 本应用流量不进 tun。ColorOS 上 protect 可能返回 false，降级为仅告警继续。
            if (!protect(upstream)) {
                Logger.w("protect(upstream) 返回 false，依赖 disallowed-self 防回环继续连接")
            }
            upstream.connect(InetSocketAddress(upstreamHost, upstreamPort), TIMEOUT_MS)
            upstream.soTimeout = TIMEOUT_MS
            val out = upstream.getOutputStream()
            val req = "CONNECT $targetHost:$targetPort HTTP/1.1\r\n" +
                "Host: $targetHost:$targetPort\r\n\r\n"
            out.write(req.toByteArray(Charsets.ISO_8859_1))
            out.flush()

            val header = readHeader(upstream)
            val status = parseStatusCode(header) ?: run {
                passthrough(appSocket, upstream, header)
                throw TunnelException("TUNNEL_HANDSHAKE_FAILED", "CONNECT 响应状态行不合法")
            }
            if (status !in 200..299) {
                passthrough(appSocket, upstream, header)
                throw TunnelException("TUNNEL_HANDSHAKE_FAILED", "CONNECT 上游返回 $status")
            }
            upstream.soTimeout = 0
            return upstream
        } catch (e: TunnelException) {
            runCatching { upstream.close() }
            throw e
        } catch (e: IOException) {
            runCatching { upstream.close() }
            throw when (e) {
                is java.net.SocketTimeoutException, is EOFException ->
                    TunnelException("UPSTREAM_UNREACHABLE", "连接上游超时或被重置", e)
                is java.net.ConnectException, is java.net.NoRouteToHostException, is java.net.SocketException ->
                    TunnelException("UPSTREAM_UNREACHABLE", "连不上上游 ${upstreamHost}:${upstreamPort}（${e.message}）", e)
                else ->
                    TunnelException("UPSTREAM_UNREACHABLE", "上游连接失败（${e.message}）", e)
            }
        }
    }

    /** 逐字节读至 \r\n\r\n，绝不越过边界（条款 4） */
    private fun readHeader(socket: Socket): ByteArray {
        val inp = socket.getInputStream()
        val buf = ByteArrayOutputStream()
        var matched = 0
        val tail = byteArrayOf('\r'.code.toByte(), '\n'.code.toByte(), '\r'.code.toByte(), '\n'.code.toByte())
        while (buf.size() < HEADER_LIMIT) {
            val b = inp.read()
            if (b < 0) throw EOFException("读取 CONNECT 响应时上游关闭连接")
            buf.write(b)
            if (b.toByte() == tail[matched]) {
                matched++
                if (matched == 4) return buf.toByteArray()
            } else {
                matched = if (b.toByte() == tail[0]) 1 else 0
            }
        }
        throw IOException("CONNECT 响应头超过 ${HEADER_LIMIT}B 上限")
    }

    private fun parseStatusCode(header: ByteArray): Int? {
        val lineEnd = header.indexOfBytes(byteArrayOf('\r'.code.toByte(), '\n'.code.toByte()))
        if (lineEnd <= 0) return null
        val line = String(header, 0, lineEnd, Charsets.ISO_8859_1)
        val parts = line.split(' ')
        if (parts.size < 2 || !parts[0].startsWith("HTTP/")) return null
        return parts[1].toIntOrNull()
    }

    /** 非 2xx：把响应头（及随后短暂到达的正文）原样透传给应用侧 */
    private fun passthrough(appSocket: Socket, upstream: Socket, header: ByteArray) {
        try {
            val out = appSocket.getOutputStream()
            out.write(header)
            out.flush()
            upstream.soTimeout = DRAIN_TIMEOUT_MS
            val inp = upstream.getInputStream()
            val buf = ByteArray(8 * 1024)
            try {
                while (true) {
                    val n = inp.read(buf)
                    if (n < 0) break
                    if (n > 0) {
                        out.write(buf, 0, n)
                        out.flush()
                    }
                }
            } catch (_: java.net.SocketTimeoutException) {
                // 正文排干窗口结束
            }
        } catch (e: IOException) {
            Logger.w("CONNECT 非2xx透传失败（应用侧已断开）: ${e.message}")
        }
    }

    private fun ByteArray.indexOfBytes(needle: ByteArray): Int {
        outer@ for (i in 0..(size - needle.size)) {
            for (j in needle.indices) {
                if (this[i + j] != needle[j]) continue@outer
            }
            return i
        }
        return -1
    }
}
