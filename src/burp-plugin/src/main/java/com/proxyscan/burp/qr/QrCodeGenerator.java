package com.proxyscan.burp.qr;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.EncodeHintType;
import com.google.zxing.WriterException;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.Map;

/**
 * 二维码生成器：把代理配置 URI 渲染为 PNG（zxing core，无需 javase 模块）。
 *
 * <p>格式约定见项目 doc/qr-format-spec.md：标准 URI {@code http://host:port}。
 */
public class QrCodeGenerator {

    /** 纠错级别 M（约 15%），平衡密度与容错；白边 2 module */
    private static final Map<EncodeHintType, Object> HINTS = Map.of(
            EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.M,
            EncodeHintType.MARGIN, 2
    );

    /**
     * 将代理配置 URI 编码为 PNG 二维码字节流。
     *
     * @param uri  代理配置 URI，如 {@code http://192.168.1.10:8080}
     * @param size 边长像素数（宽高相等）
     * @return PNG 字节流
     * @throws QrGenerateException 编码失败（内容过长等）
     */
    public byte[] toPng(String uri, int size) {
        if (uri == null || uri.isBlank()) {
            throw new QrGenerateException("URI 不能为空");
        }
        if (size < 64 || size > 2048) {
            throw new QrGenerateException("尺寸需在 64-2048 像素之间");
        }
        try {
            BitMatrix matrix = new QRCodeWriter().encode(uri, BarcodeFormat.QR_CODE, size, size, HINTS);
            BufferedImage image = toBufferedImage(matrix);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            ImageIO.write(image, "PNG", out);
            return out.toByteArray();
        } catch (WriterException | IOException e) {
            throw new QrGenerateException("二维码生成失败：" + e.getMessage(), e);
        }
    }

    private static BufferedImage toBufferedImage(BitMatrix matrix) {
        int width = matrix.getWidth();
        int height = matrix.getHeight();
        BufferedImage image = new BufferedImage(width, height, BufferedImage.TYPE_INT_RGB);
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                image.setRGB(x, y, matrix.get(x, y) ? 0xFF000000 : 0xFFFFFFFF);
            }
        }
        return image;
    }

    /** 生成失败（向 UI 层透出的受检异常包装）。 */
    public static class QrGenerateException extends RuntimeException {
        public QrGenerateException(String message) {
            super(message);
        }

        public QrGenerateException(String message, Throwable cause) {
            super(message, cause);
        }
    }
}
