package com.proxyscan.proxy_config_scan.bridge

import com.proxyscan.proxy_config_scan.util.Logger
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicLong

/**
 * udpgw 转发器（doc/vpn-forwarding-design.md §5）。
 *
 * 传输：tun2socks 的 SocksUdpGwClient 经 **TCP** 连本机 127.0.0.1:7300，
 * 消息用 PacketProto 帧封装（2B 大端长度 + 载荷）。
 * 载荷 = udpgw_header(1B flags + 2B conid) + 地址(IPv4=4B IP+2B 端口) + DNS payload；
 * flags: KEEPALIVE=1 / DNS=4 / IPV6=8。
 *
 * 行为：仅放行目标端口 53（conid/原始地址回填响应，多查询并发线程处理，
 * 写口加锁防帧交错）；KEEPALIVE 原样回应；IPv6 与非 53 端口丢弃并 udpDropped++。
 */
class DnsForwarder(
    private val listenPort: Int = 7300,
    private val dnsServer: String = "223.5.5.5",
    private val protect: (DatagramSocket) -> Boolean,
    private val dnsQueries: AtomicLong,
    private val udpDropped: AtomicLong,
) : AutoCloseable {
    companion object {
        private const val FLAG_KEEPALIVE = 0x01
        private const val FLAG_DNS = 0x04
        private const val FLAG_IPV6 = 0x08
        private const val QUERY_TIMEOUT_MS = 3_000
        private const val MAX_FRAME = 4096
    }

    @Volatile
    private var running = false
    private var serverSocket: ServerSocket? = null
    private val connections = CopyOnWriteArraySet<Socket>()

    fun start() {
        val ss = ServerSocket(listenPort, 16, InetAddress.getByName("127.0.0.1"))
        serverSocket = ss
        running = true
        Thread({ acceptLoop(ss) }, "dns-forwarder").start()
        Logger.d("DnsForwarder 已监听 TCP 127.0.0.1:$listenPort → $dnsServer:53")
    }

    override fun close() {
        running = false
        runCatching { serverSocket?.close() }
        connections.forEach { runCatching { it.close() } }
        connections.clear()
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (running) {
            try {
                val conn = ss.accept()
                connections.add(conn)
                Thread({ handleConn(conn) }, "udpgw-conn").start()
            } catch (_: IOException) {
                break
            }
        }
    }

    private fun handleConn(conn: Socket) {
        try {
            val inp = conn.getInputStream()
            val out = conn.getOutputStream()
            val outLock = Any()
            while (running) {
                val lenBytes = readFully(inp, 2) ?: break
                // PacketProto 帧长为 16 位小端（badvpn 协议全小端，仅 BAddr 端口按网络字节序）
                val len = (lenBytes[0].toInt() and 0xFF) or ((lenBytes[1].toInt() and 0xFF) shl 8)
                if (len < 3 || len > MAX_FRAME) {
                    Logger.w("udpgw 帧长度非法: $len")
                    break
                }
                val msg = readFully(inp, len) ?: break
                val flags = msg[0].toInt()
                val conid = (msg[1].toInt() and 0xFF) or ((msg[2].toInt() and 0xFF) shl 8)

                if (flags and FLAG_KEEPALIVE != 0) {
                    // KEEPALIVE 原样回显（flags+conid，无地址）
                    writeFrame(out, outLock, byteArrayOf(msg[0], msg[1], msg[2]))
                    continue
                }

                val isV6 = flags and FLAG_IPV6 != 0
                val addrLen = if (isV6) 18 else 6
                if (msg.size < 3 + addrLen) {
                    Logger.w("udpgw 帧缺地址段: len=${msg.size}")
                    continue
                }
                // BAddr 端口在网络字节序（大端）直通
                val port = ((msg[3 + addrLen - 2].toInt() and 0xFF) shl 8) or
                    (msg[3 + addrLen - 1].toInt() and 0xFF)
                if (isV6 || port != 53) {
                    udpDropped.incrementAndGet()
                    continue
                }
                val dstIp = msg.copyOfRange(3, 7)
                val payload = msg.copyOfRange(3 + addrLen, msg.size)
                dnsQueries.incrementAndGet()
                Thread(
                    { resolveAndReply(conn, out, outLock, conid, dstIp, port, payload) },
                    "dns-query",
                ).start()
            }
        } catch (_: IOException) {
            // 对端断开或关闭
        } catch (t: Throwable) {
            Logger.w("udpgw 连接处理异常: ${t.message}")
        } finally {
            connections.remove(conn)
            runCatching { conn.close() }
        }
    }

    private fun resolveAndReply(
        conn: Socket,
        out: OutputStream,
        outLock: Any,
        conid: Int,
        dstIp: ByteArray,
        dstPort: Int,
        payload: ByteArray,
    ) {
        val upstream = DatagramSocket()
        try {
            if (!protect(upstream)) {
                Logger.w("protect(DNS 上游) 返回 false，依赖 disallowed-self 继续")
            }
            upstream.soTimeout = QUERY_TIMEOUT_MS
            upstream.send(DatagramPacket(payload, payload.size, InetAddress.getByName(dnsServer), 53))
            val buf = ByteArray(2048)
            val resp = DatagramPacket(buf, buf.size)
            upstream.receive(resp)
            val payloadOut = resp.data.copyOfRange(resp.offset, resp.offset + resp.length)

            // 响应帧：flags(DNS) + conid(小端) + 原始地址(端口原字节回填) + payload
            val body = ByteArrayOutputStream()
            body.write(FLAG_DNS)
            body.write(conid and 0xFF)
            body.write((conid shr 8) and 0xFF)
            body.write(dstIp)
            body.write(dstPort shr 8)
            body.write(dstPort and 0xFF)
            body.write(payloadOut)
            if (!conn.isClosed) {
                writeFrame(out, outLock, body.toByteArray())
            }
        } catch (e: IOException) {
            Logger.w("DNS 转发失败: ${e.message}")
        } finally {
            runCatching { upstream.close() }
        }
    }

    /** PacketProto 帧：2B 小端长度 + 载荷（badvpn 协议小端约定），写口持锁防帧交错 */
    private fun writeFrame(out: OutputStream, lock: Any, body: ByteArray) {
        synchronized(lock) {
            out.write(body.size and 0xFF)
            out.write((body.size shr 8) and 0xFF)
            out.write(body)
            out.flush()
        }
    }

    private fun readFully(inp: InputStream, n: Int): ByteArray? {
        val buf = ByteArray(n)
        var off = 0
        while (off < n) {
            val r = inp.read(buf, off, n - off)
            if (r < 0) return null
            off += r
        }
        return buf
    }
}
