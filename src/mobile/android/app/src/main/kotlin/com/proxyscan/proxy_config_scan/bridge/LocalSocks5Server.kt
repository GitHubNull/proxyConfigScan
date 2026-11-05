package com.proxyscan.proxy_config_scan.bridge

import com.proxyscan.proxy_config_scan.util.Logger
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger

/**
 * 127.0.0.1:10808 本地 SOCKS5 桥：no-auth 子集 + CONNECT 命令。
 * 每个连接：SOCKS5 握手 → CONNECT target → HttpConnectTunnel 建立到 Burp 的隧道
 * → ByteRelay 双向转发。上游地址由 [upstreamProvider] 在每次连接时取当前值。
 */
class LocalSocks5Server(
    private val port: Int = 10808,
    private val upstreamProvider: () -> Pair<String, Int>?,
    private val protect: (Socket) -> Boolean,
    private val activeConnections: AtomicInteger,
    private val onChunk: (bytes: Long, aToB: Boolean) -> Unit,
    private val onSuccess: () -> Unit,
    private val onFailure: (code: String, detail: String) -> Unit,
) : AutoCloseable {
    @Volatile
    private var running = false
    private var serverSocket: ServerSocket? = null

    fun start() {
        val ss = ServerSocket(port, 64, InetAddress.getByName("127.0.0.1"))
        serverSocket = ss
        running = true
        Thread({ acceptLoop(ss) }, "socks5-accept").start()
        Logger.d("本地桥已监听 127.0.0.1:$port")
    }

    override fun close() {
        running = false
        runCatching { serverSocket?.close() }
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (running) {
            try {
                val client = ss.accept()
                activeConnections.incrementAndGet()
                Thread({ handleClient(client) }, "socks5-conn").start()
            } catch (_: IOException) {
                break
            }
        }
    }

    private fun handleClient(client: Socket) {
        try {
            client.soTimeout = HttpConnectTunnel.TIMEOUT_MS
            val inp = client.getInputStream()
            val out = client.getOutputStream()

            // --- 方法协商：仅 no-auth(0x00) ---
            if (inp.read() != 0x05) throw IOException("非 SOCKS5 握手")
            val nMethods = inp.read()
            if (nMethods < 0) throw EOFException()
            val methods = readFully(inp, nMethods)
            if (!methods.contains(0x00.toByte())) {
                out.write(byteArrayOf(0x05, 0xFF.toByte()))
                out.flush()
                throw IOException("客户端不支持 no-auth")
            }
            out.write(byteArrayOf(0x05, 0x00))
            out.flush()

            // --- CONNECT 请求 ---
            if (inp.read() != 0x05) throw IOException("请求版本错误")
            val cmd = inp.read()
            if (cmd != 0x01) {
                replyCommandError(out, 0x07)
                throw IOException("不支持 CMD=$cmd（仅 CONNECT）")
            }
            inp.read() // RSV
            val target = readAddress(inp)
                ?: run {
                    replyCommandError(out, 0x08)
                    throw IOException("不支持的地址类型")
                }

            val upstream = upstreamProvider() ?: throw IOException("上游未配置")
            // badvpn 把 udpgw（127.0.0.1:7300）也走 SOCKS CONNECT；环回目标必须本机直连，
            // 否则 CONNECT 会要求上游代理去连它自己的回环，DNS 转发即失效
            val tunnel = try {
                if (isLoopbackHost(target.first)) {
                    directConnect(target, protect)
                } else {
                    HttpConnectTunnel.establish(client, upstream.first, upstream.second, target.first, target.second, protect)
                }
            } catch (e: HttpConnectTunnel.TunnelException) {
                onFailure(e.code, "${target.first}:${target.second} → ${e.message}")
                replyCommandError(out, if (e.code == "TUNNEL_HANDSHAKE_FAILED") 0x05 else 0x01)
                throw e
            } catch (e: IOException) {
                onFailure("INTERNAL", "${target.first}:${target.second} → ${e.message}")
                replyCommandError(out, 0x01)
                throw e
            }
            client.soTimeout = 0
            out.write(byteArrayOf(0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
            out.flush()
            onSuccess()

            ByteRelay(client, tunnel, onChunk).also { it.start(); it.await() }
        } catch (t: Throwable) {
            Logger.w("SOCKS5 连接处理失败: ${t.message}")
        } finally {
            activeConnections.decrementAndGet()
            runCatching { client.close() }
        }
    }

    /** atyp: 0x01 IPv4 / 0x03 域名 / 0x04 IPv6。返回 host 与 port */
    private fun readAddress(inp: InputStream): Pair<String, Int>? {
        return when (val atyp = inp.read()) {
            0x01 -> {
                val raw = readFully(inp, 4)
                val host = raw.joinToString(".") { (it.toInt() and 0xFF).toString() }
                val port = readPort(inp)
                host to port
            }
            0x03 -> {
                val len = inp.read()
                if (len <= 0) throw EOFException()
                val host = String(readFully(inp, len), Charsets.ISO_8859_1)
                val port = readPort(inp)
                host to port
            }
            0x04 -> null // IPv6 不支持（known-limitations）
            else -> null
        }
    }

    /** 环回目标（udpgw 等）本机直连，不经过上游 CONNECT */
    private fun directConnect(target: Pair<String, Int>, protect: (Socket) -> Boolean): Socket {
        val s = Socket()
        if (!protect(s)) {
            s.close()
            throw IOException("VpnService.protect 失败")
        }
        s.connect(InetSocketAddress(target.first, target.second), HttpConnectTunnel.TIMEOUT_MS)
        s.soTimeout = 0
        return s
    }

    private fun isLoopbackHost(host: String): Boolean =
        host == "127.0.0.1" || host == "::1" || host.equals("localhost", ignoreCase = true)

    private fun readPort(inp: InputStream): Int {
        val raw = readFully(inp, 2)
        return ((raw[0].toInt() and 0xFF) shl 8) or (raw[1].toInt() and 0xFF)
    }

    /** InputStream.readNBytes(int) 是 API33+，低版本设备 NoSuchMethodError，这里用循环读替代 */
    private fun readFully(inp: InputStream, n: Int): ByteArray {
        val buf = ByteArray(n)
        var off = 0
        while (off < n) {
            val r = inp.read(buf, off, n - off)
            if (r < 0) throw EOFException()
            off += r
        }
        return buf
    }

    private fun replyCommandError(out: OutputStream, code: Byte) {
        runCatching { out.write(byteArrayOf(0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0)); out.flush() }
    }
}
