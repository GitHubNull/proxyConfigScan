package com.proxyscan.burp;

import burp.api.montoya.BurpExtension;
import burp.api.montoya.MontoyaApi;

/**
 * ProxyScan 二维码插件入口。
 *
 * <p>本期为骨架：完成扩展加载、基本信息注册与依赖链路验证。
 * 迭代期功能：读取 Burp Proxy listener 地址 → 生成 http://host:port 二维码
 * （格式见项目 doc/qr-format-spec.md）→ 在 Burp UI 中展示。
 */
public class ProxyQrExtension implements BurpExtension {

    private MontoyaApi api;

    @Override
    public void initialize(MontoyaApi api) {
        this.api = api;

        api.extension().setName("ProxyScan QR");
        api.logging().logToOutput("ProxyScan QR 插件已加载（本期仅骨架，二维码生成待迭代）");
        api.logging().logToError("ProxyScan QR loaded (skeleton)");
    }
}
