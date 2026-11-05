package com.proxyscan.proxy_config_scan.bridge

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicLong

/**
 * 双向 relay：A↔B 字节搬运 + 半关闭传播 + ECONNRESET 静默关双 + 字节计数。
 * 任一侧 read==-1 → 对向 shutdownOutput（FIN 传播），另一侧继续；
 * 一侧异常（RST）→ 静默关闭双侧以解除另一侧阻塞；两侧都结束后 await 返回。
 */
class ByteRelay(
    private val socketA: Socket,
    private val socketB: Socket,
    private val onChunk: (bytes: Long, aToB: Boolean) -> Unit,
) {
    private val done = CountDownLatch(2)
    val aToBBytes = AtomicLong(0)
    val bToABytes = AtomicLong(0)

    fun start() {
        Thread({ pump(socketA.getInputStream(), socketB.getOutputStream(), socketB, aToBBytes, true) }, "relay-a-to-b").start()
        Thread({ pump(socketB.getInputStream(), socketA.getOutputStream(), socketA, bToABytes, false) }, "relay-b-to-a").start()
    }

    /** 阻塞至双向 relay 都结束（调用方一般不在 UI 线程调用） */
    fun await() {
        runCatching { done.await() }
    }

    private fun pump(inp: InputStream, out: OutputStream, peerOfEof: Socket, counter: AtomicLong, aToB: Boolean) {
        val buf = ByteArray(16 * 1024)
        try {
            while (true) {
                val n = inp.read(buf)
                if (n < 0) break
                if (n > 0) {
                    out.write(buf, 0, n)
                    out.flush()
                    counter.addAndGet(n.toLong())
                    onChunk(n.toLong(), aToB)
                }
            }
            // 本侧 EOF：向对端传播 FIN，另一侧照常继续
            runCatching { peerOfEof.shutdownOutput() }
        } catch (_: IOException) {
            // ECONNRESET / 对端已关：静默，关闭双侧解除另一侧阻塞
            runCatching { socketA.close() }
            runCatching { socketB.close() }
        } catch (_: Throwable) {
            runCatching { socketA.close() }
            runCatching { socketB.close() }
        } finally {
            done.countDown()
        }
    }
}
