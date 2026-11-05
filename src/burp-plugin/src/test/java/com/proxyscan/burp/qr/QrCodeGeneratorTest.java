package com.proxyscan.burp.qr;

import com.google.zxing.BinaryBitmap;
import com.google.zxing.RGBLuminanceSource;
import com.google.zxing.Result;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.qrcode.QRCodeReader;
import org.junit.jupiter.api.Test;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class QrCodeGeneratorTest {

    private final QrCodeGenerator generator = new QrCodeGenerator();

    @Test
    void 生成PNG结构合法() {
        byte[] png = generator.toPng("http://192.168.1.10:8080", 256);
        // PNG 魔数 \x89PNG\r\n\x1a\n
        assertArrayEquals(
                new byte[]{(byte) 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A},
                new byte[]{png[0], png[1], png[2], png[3], png[4], png[5], png[6], png[7]});
        assertTrue(png.length > 100);
    }

    @Test
    void 生成后可解码回原文() throws Exception {
        String uri = "http://192.168.31.94:8081";
        byte[] png = generator.toPng(uri, 256);

        BufferedImage image = ImageIO.read(new ByteArrayInputStream(png));
        int[] pixels = image.getRGB(0, 0, image.getWidth(), image.getHeight(), null, 0, image.getWidth());
        BinaryBitmap bitmap = new BinaryBitmap(new HybridBinarizer(
                new RGBLuminanceSource(image.getWidth(), image.getHeight(), pixels)));
        Result result = new QRCodeReader().decode(bitmap);
        assertEquals(uri, result.getText());
    }

    @Test
    void 空URI拒绝() {
        assertThrows(QrCodeGenerator.QrGenerateException.class,
                () -> generator.toPng(" ", 256));
    }

    @Test
    void 尺寸越界拒绝() {
        assertThrows(QrCodeGenerator.QrGenerateException.class,
                () -> generator.toPng("http://192.168.1.10:8080", 10));
    }
}
