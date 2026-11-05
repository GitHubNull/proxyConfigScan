package com.proxyscan.burp;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ProxyListenerDetectorTest {

    @Test
    void 路径查询形态直接是监听器数组() {
        String json = """
                [
                  {"listener_port": 8080, "listener_address": "", "running": true},
                  {"listener_port": 8081, "listener_address": "127.0.0.1", "running": true}
                ]
                """;
        List<ProxyListenerDetector.Listener> listeners = ProxyListenerDetector.parse(json);
        assertEquals(2, listeners.size());
        assertTrue(listeners.get(0).isAnyInterface());
        assertFalse(listeners.get(0).isLoopback());
        assertTrue(listeners.get(1).isLoopback());
        assertEquals(8081, listeners.get(1).port());
    }

    @Test
    void 全量导出形态按user_options嵌套解析() {
        String json = """
                {"user_options": {"proxy": {"proxy_request_listeners": [
                  {"listener_port": 8080, "listener_address": "0.0.0.0"},
                  {"listener_port": 9090, "listener_address": "192.168.1.10"}
                ]}}}
                """;
        List<ProxyListenerDetector.Listener> listeners = ProxyListenerDetector.parse(json);
        assertEquals(2, listeners.size());
        assertTrue(listeners.get(0).isAnyInterface());
        assertEquals("192.168.1.10", listeners.get(1).address());
    }

    @Test
    void 全量导出project_options根也可解析() {
        String json = """
                {"project_options": {"proxy": {"proxy_request_listeners": [
                  {"listener_port": 8080, "listener_address": "", "running": true}
                ]}}}
                """;
        List<ProxyListenerDetector.Listener> listeners = ProxyListenerDetector.parse(json);
        assertEquals(1, listeners.size());
        assertEquals(8080, listeners.get(0).port());
    }

    @Test
    void 停用的监听器被跳过() {
        String json = """
                [{"listener_port": 8080, "listener_address": "", "running": false},
                 {"listener_port": 8082, "listener_address": "", "running": true}]
                """;
        List<ProxyListenerDetector.Listener> listeners = ProxyListenerDetector.parse(json);
        assertEquals(1, listeners.size());
        assertEquals(8082, listeners.get(0).port());
    }

    @Test
    void 空或异常输入返回空表() {
        assertTrue(ProxyListenerDetector.parse("").isEmpty());
        assertTrue(ProxyListenerDetector.parse(null).isEmpty());
        assertTrue(ProxyListenerDetector.parse("{}").isEmpty());
        assertTrue(ProxyListenerDetector.parse("{\"user_options\":{}}").isEmpty());
    }
}
