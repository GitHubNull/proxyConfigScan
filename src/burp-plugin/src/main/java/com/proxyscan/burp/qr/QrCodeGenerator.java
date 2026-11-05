package com.proxyscan.burp.qr;

/**
 * 二维码生成器。迭代期使用 ZXing 将代理配置 URI 渲染为 PNG。
 *
 * <p>格式约定见项目 doc/qr-format-spec.md：标准 URI {@code http://host:port}。
 */
public class QrCodeGenerator {

    /**
     * 将代理配置 URI 编码为 PNG 二维码字节流。
     *
     * @param uri  代理配置 URI，如 {@code http://192.168.1.10:8080}
     * @param size 边长像素数（宽高相等）
     * @return PNG 字节流
     */
    public byte[] toPng(String uri, int size) {
        // TODO 迭代期实现：zxing MultiFormatWriter + MatrixToImageWriter，
        //  纠错级别 M，白边 2 module
        throw new UnsupportedOperationException("二维码生成将在迭代期实现");
    }
}
