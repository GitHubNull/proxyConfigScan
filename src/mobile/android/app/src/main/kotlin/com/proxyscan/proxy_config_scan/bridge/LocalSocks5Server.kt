package com.proxyscan.proxy_config_scan.bridge

import com.proxyscan.proxy_config_scan.util.Logger
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
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
            val methods = inp.readNBytes(nMethods)
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
            val tunnel = try {
                HttpConnectTunnel.establish(client, upstream.first, upstream.second, target.first, target.second, protect)
            } catch (e: HttpConnectTunnel.TunnelException) {
                onFailure(e.code, "${target.first}:${target.second} → ${e.message}")
                replyCommandError(out, if (e.code == "TUNNEL_HANDSHAKE_FAILED") 0x05 else 0x01)
                throw e
            }
            client.soTimeout = 0
            out.write(byteArrayOf(0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
            out.flush()
            onSuccess()

            ByteRelay(client, tunnel, onChunk).also { it.start(); it.await() }
        } catch (_: Throwable) {
            // 单连接失败不影响监听；异常明细已在 onFailure/Logger 落点上报
        } finally {
            activeConnections.decrementAndGet()
            runCatching { client.close() }
        }
    }

    /** atyp: 0x01 IPv4 / 0x03 域名 / 0x04 IPv6。返回 host 与 port */
    private fun readAddress(inp: InputStream): Pair<String, Int>? {
        return when (val atyp = inp.read()) {
            0x01 -> {
                val raw = inp.readNBytes(4)
                if (raw.size < 4) throw EOFException()
                val host = raw.joinToString(".") { (it.toInt() and 0xFF).toString() }
                val port = readPort(inp)
                host to port
            }
            0x03 -> {
                val len = inp.read()
                if (len <= 0) throw EOFException()
                val host = String(inp.readNBytes(len), Charsets.ISO_8859_1)
                val port = readPort(inp)
                host to port
            }
            0x04 -> null // IPv6 不支持（known-limitations）
            else -> null
        }
    }

    private fun readPort(inp: InputStream): Int {
        val raw = inp.readNBytes(2)
        if (raw.size < 2) throw EOFException()
        return ((raw[0].toInt() and 0xFF) shl 8) or (raw[1].toInt() and 0xFF)
    }

    private fun replyCommandError(out: OutputStream, code: Byte) {
        runCatching { out.write(byteArrayOf(0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0)); out.flush() }
    }
}
