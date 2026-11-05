package com.proxyscan.proxy_config_scan.bridge

import com.proxyscan.proxy_config_scan.util.Logger
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicLong

/**
 * udpgw 线格式解析 + 公共 DNS 转发（doc/vpn-forwarding-design.md §5）：
 * 请求帧 = flags(2B) + port(2B BE) + addr(4B BE) + payload；
 * 仅放行目标端口 53，payload 经 protected UDP 发 [dnsServer]:53；
 * 响应帧 flags=0x01(UDPGW_FLAG_FROM_SERVER)，addr/port 回填原始目标；
 * 其余 UDP 丢弃并 udpDropped++。
 */
class DnsForwarder(
    private val listenPort: Int = 7300,
    private val dnsServer: String = "223.5.5.5",
    private val protect: (DatagramSocket) -> Boolean,
    private val dnsQueries: AtomicLong,
    private val udpDropped: AtomicLong,
) : AutoCloseable {
    companion object {
        private const val FLAG_FROM_SERVER = 0x01
        private const val QUERY_TIMEOUT_MS = 3_000
    }

    @Volatile
    private var running = false
    private var listenSocket: DatagramSocket? = null

    fun start() {
        val sock = DatagramSocket(InetSocketAddress("127.0.0.1", listenPort))
        listenSocket = sock
        running = true
        Thread({ loop(sock) }, "dns-forwarder").start()
        Logger.d("DnsForwarder 已监听 127.0.0.1:$listenPort → $dnsServer:53")
    }

    override fun close() {
        running = false
        runCatching { listenSocket?.close() }
    }

    private fun loop(sock: DatagramSocket) {
        val buf = ByteArray(2048)
        while (running) {
            try {
                val pkt = DatagramPacket(buf, buf.size)
                sock.receive(pkt)
                val data = pkt.data.copyOfRange(pkt.offset, pkt.offset + pkt.length)
                if (data.size < 8) continue
                val port = ((data[2].toInt() and 0xFF) shl 8) or (data[3].toInt() and 0xFF)
                if (port != 53) {
                    udpDropped.incrementAndGet()
                    continue
                }
                val dstAddr = byteArrayOf(data[4], data[5], data[6], data[7])
                val payload = data.copyOfRange(8, data.size)
                dnsQueries.incrementAndGet()
                val replyTo = pkt.socketAddress
                Thread({ resolveAndReply(sock, replyTo, dstAddr, port, payload) }, "dns-query").start()
            } catch (_: IOException) {
                break
            }
        }
    }

    private fun resolveAndReply(listen: DatagramSocket, replyTo: java.net.SocketAddress, dstAddr: ByteArray, dstPort: Int, payload: ByteArray) {
        val upstream = DatagramSocket()
        try {
            if (!protect(upstream)) {
                Logger.w("protect(DNS 上游) 返回 false，依赖 disallowed-self 继续")
            }
            upstream.soTimeout = QUERY_TIMEOUT_MS
            val dnsInet = InetAddress.getByName(dnsServer)
            upstream.send(DatagramPacket(payload, payload.size, dnsInet, 53))
            val respBuf = ByteArray(2048)
            val resp = DatagramPacket(respBuf, respBuf.size)
            upstream.receive(resp)
            val respPayload = resp.data.copyOfRange(resp.offset, resp.offset + resp.length)

            // 响应帧：flags(0x01,0x00) + port + addr + payload
            val frame = ByteArray(8 + respPayload.size)
            frame[0] = FLAG_FROM_SERVER.toByte()
            frame[1] = 0
            frame[2] = (dstPort shr 8).toByte()
            frame[3] = (dstPort and 0xFF).toByte()
            System.arraycopy(dstAddr, 0, frame, 4, 4)
            System.arraycopy(respPayload, 0, frame, 8, respPayload.size)
            listen.send(DatagramPacket(frame, frame.size, replyTo))
        } catch (e: IOException) {
            Logger.w("DNS 转发失败: ${e.message}")
        } finally {
            runCatching { upstream.close() }
        }
    }
}
