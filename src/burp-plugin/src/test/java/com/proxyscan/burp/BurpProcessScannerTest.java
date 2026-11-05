package com.proxyscan.burp;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class BurpProcessScannerTest {

    @Test
    void 十六进制小端IPv4解码() {
        assertEquals("127.0.0.1", BurpProcessScanner.decodeIp("0100007F", false));
        assertEquals("0.0.0.0", BurpProcessScanner.decodeIp("00000000", false));
        assertEquals("192.168.31.94", BurpProcessScanner.decodeIp("5E1FA8C0", false));
    }

    @Test
    void proc_net_tcp只取监听态并解析inode() {
        String content = """
                sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
                 0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1111111 1 0000000000000000 100 0 0 10 0
                 1: 5E1FA8C0:1F91 00000000:0000 01 00000000:00000000 00:00000000 00000000  1000        0 2222222 1 0000000000000000 100 0 0 10 0
                 2: 5E1FA8C0:1F92 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 3333333 1 0000000000000000 100 0 0 10 0
                """;
        Map<String, ProxyListenerDetector.Listener> inodes = BurpProcessScanner.parseProcNetTcp(content, false);
        assertEquals(2, inodes.size());
        assertEquals("127.0.0.1", inodes.get("1111111").address());
        assertEquals(8080, inodes.get("1111111").port());
        assertEquals("192.168.31.94", inodes.get("3333333").address());
        assertEquals(8082, inodes.get("3333333").port());
        assertNull(inodes.get("2222222")); // 非 LISTEN 态不入表
    }

    @Test
    void v4映射IPv6回环解码为IPv4() {
        // ::ffff:127.0.0.1（本机 Burp 实测形态）
        assertEquals("127.0.0.1", BurpProcessScanner.decodeIp("0000000000000000FFFF00000100007F", true));
        assertEquals("::", BurpProcessScanner.decodeIp("00000000000000000000000000000000", true));
        assertEquals("::1", BurpProcessScanner.decodeIp("00000000000000000000000001000000", true));
    }

    @Test
    void netstat行按pid过滤且只取监听() {
        List<Long> burp = List.of(7680L);
        ProxyListenerDetector.Listener hit = BurpProcessScanner.parseNetstatLine(
                "  TCP    0.0.0.0:8080           0.0.0.0:0              LISTENING       7680", burp);
        assertEquals(8080, hit.port());
        assertEquals("0.0.0.0", hit.address());

        assertNull(BurpProcessScanner.parseNetstatLine(
                "  TCP    0.0.0.0:3306           0.0.0.0:0              LISTENING       1234", burp));
        assertNull(BurpProcessScanner.parseNetstatLine(
                "  TCP    127.0.0.1:8080         127.0.0.1:5555         ESTABLISHED     7680", burp));
        assertNull(BurpProcessScanner.parseNetstatLine("  Proto  Local Address          Foreign Address        State           PID", burp));
    }

    @Test
    void 空内容返回空表() {
        assertTrue(BurpProcessScanner.parseProcNetTcp("", false).isEmpty());
        assertTrue(BurpProcessScanner.parseProcNetTcp("sl  local_address rem_address\n", false).isEmpty());
    }
}
