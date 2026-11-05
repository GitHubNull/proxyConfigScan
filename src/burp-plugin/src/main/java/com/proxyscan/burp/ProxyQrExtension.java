package com.proxyscan.burp;

import burp.api.montoya.BurpExtension;
import burp.api.montoya.MontoyaApi;

/**
 * ProxyScan 二维码插件入口。
 *
 * <p>功能：在 Burp 中新增「ProxyScan QR」标签页，填代理地址生成二维码，
 * 供 ProxyScan 移动应用扫码自动完成抓包代理配置（格式见 doc/qr-format-spec.md）。
 */
public class ProxyQrExtension implements BurpExtension {

    @Override
    public void initialize(MontoyaApi api) {
        api.extension().setName("ProxyScan QR");
        ProxyListenerDetector detector = new ProxyListenerDetector(api);
        api.userInterface().registerSuiteTab("ProxyScan QR", new ProxyQrTab(api.logging(), detector::detect));
        api.logging().logToOutput("ProxyScan QR 插件已加载：标签页自动读取 Burp 代理监听器生成二维码");
    }
}
