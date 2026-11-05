package com.proxyscan.burp;

import burp.api.montoya.MontoyaApi;
import burp.api.montoya.logging.Logging;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.util.ArrayList;
import java.util.List;

/**
 * 读取 Burp Proxy 监听器配置。
 *
 * <p>montoya-api 2026.7 无监听器枚举接口（{@code api.proxy()} 仅暴露 history/handler），
 * 官方途径是 {@code api.burpSuite().exportUserOptionsAsJson("proxy.proxy_request_listeners")}
 * 导出运行中的实时配置，这里负责导出与解析。
 *
 * <p>解析对两种返回形态容错：
 * <ol>
 *   <li>按路径查询：直接返回监听器数组</li>
 *   <li>全量导出：{@code user_options.proxy.proxy_request_listeners} 嵌套结构</li>
 * </ol>
 */
public class ProxyListenerDetector {

    private final MontoyaApi api;
    private final Logging logging;

    public ProxyListenerDetector(MontoyaApi api) {
        this.api = api;
        this.logging = api.logging();
    }

    /** 一条监听器：原始绑定地址 + 端口。 */
    public record Listener(String address, int port) {
        /** 绑定是否为回环（扫码不可达，仅本机可用）。 */
        public boolean isLoopback() {
            return address.isEmpty()
                    ? false // 空串 = 绑全部接口，可达
                    : address.equals("127.0.0.1") || address.equals("::1") || address.equalsIgnoreCase("localhost");
        }

        /** 绑定是否为全部接口（0.0.0.0 / :: / 空串）。 */
        public boolean isAnyInterface() {
            return address.isEmpty() || address.equals("0.0.0.0") || address.equals("::");
        }

        @Override
        public String toString() {
            String display = address.isEmpty() ? "0.0.0.0（全部接口）" : address;
            return display + ":" + port;
        }
    }

    /** 读取当前配置的全部 Proxy 监听器；读取失败返回空表。 */
    public List<Listener> detect() {
        // Burp 2023.9+ 代理监听器在 project options；旧版在 user options。依次尝试，命中即返回。
        for (String json : new String[]{
                export("project", "proxy.proxy_request_listeners"),
                export("user", "proxy.proxy_request_listeners"),
                export("project", null),
                export("user", null),
        }) {
            List<Listener> listeners = parse(json);
            if (!listeners.isEmpty()) return listeners;
        }
        return List.of();
    }

    private String export(String scope, String path) {
        try {
            return path == null
                    ? (scope.equals("project")
                        ? api.burpSuite().exportProjectOptionsAsJson()
                        : api.burpSuite().exportUserOptionsAsJson())
                    : (scope.equals("project")
                        ? api.burpSuite().exportProjectOptionsAsJson(path)
                        : api.burpSuite().exportUserOptionsAsJson(path));
        } catch (Exception e) {
            logging.logToError("ProxyScan QR 导出 " + scope + " options 失败：" + e.getMessage());
            return "";
        }
    }

    /** 解析监听器数组（两种形态，见类注释）。供单测直调。 */
    static List<Listener> parse(String json) {
        if (json == null || json.isBlank()) return List.of();
        JsonElement root = JsonParser.parseString(json);
        JsonArray array = null;
        if (root.isJsonArray()) {
            array = root.getAsJsonArray();
        } else if (root.isJsonObject()) {
            // 全量导出形态：{project_options|user_options}.proxy.proxy_request_listeners（逐层容错下探）
            JsonObject obj = root.getAsJsonObject();
            String rootKey = obj.has("project_options") ? "project_options" : "user_options";
            for (String key : new String[]{rootKey, "proxy", "proxy_request_listeners"}) {
                if (!obj.has(key)) break;
                JsonElement child = obj.get(key);
                if (child.isJsonArray()) {
                    array = child.getAsJsonArray();
                    break;
                }
                if (child.isJsonObject()) obj = child.getAsJsonObject();
            }
        }
        if (array == null) return List.of();

        List<Listener> out = new ArrayList<>();
        for (JsonElement el : array) {
            if (!el.isJsonObject()) continue;
            JsonObject o = el.getAsJsonObject();
            if (!o.has("listener_port")) continue;
            int port = o.get("listener_port").getAsInt();
            String address = o.has("listener_address") && !o.get("listener_address").isJsonNull()
                    ? o.get("listener_address").getAsString()
                    : "";
            if (o.has("running") && !o.get("running").getAsBoolean()) continue; // 停用的监听器不出二维码
            out.add(new Listener(address, port));
        }
        return out;
    }
}
