package com.proxyscan.burp;

import burp.api.montoya.logging.Logging;

import javax.imageio.ImageIO;
import javax.swing.JFrame;
import javax.swing.SwingUtilities;
import javax.swing.UIManager;
import java.awt.image.BufferedImage;
import java.io.File;
import java.lang.reflect.Proxy;
import java.util.List;

/**
 * 独立预览窗：FlatLaf 暗色复刻 Burp 主题，截图走查 ProxyQrTab 两种状态。
 * 用法：java com.proxyscan.burp.Preview [qr|guide]，截图写到仓库 tmp/ui-preview-*.png
 */
public class Preview {

    public static void main(String[] args) throws Exception {
        UIManager.setLookAndFeel("com.formdev.flatlaf.FlatDarkLaf");
        boolean guide = args.length > 0 && args[0].equals("guide");
        boolean show = args.length > 0 && args[0].equals("show");

        Logging logging = (Logging) Proxy.newProxyInstance(
                Preview.class.getClassLoader(), new Class<?>[]{Logging.class},
                (proxy, method, a) -> {
                    System.out.println("[" + method.getName() + "] " + (a.length > 0 ? a[0] : ""));
                    return null;
                });

        SwingUtilities.invokeAndWait(() -> {
            try {
                ProxyQrTab tab = new ProxyQrTab(logging, () -> List.of(
                        guide
                                ? new ProxyListenerDetector.Listener("127.0.0.1", 8080)
                                : new ProxyListenerDetector.Listener("0.0.0.0", 8080),
                        new ProxyListenerDetector.Listener("127.0.0.1", 8081)));

                JFrame frame = new JFrame("ProxyScan QR 预览");
                frame.setDefaultCloseOperation(JFrame.DISPOSE_ON_CLOSE);
                frame.setContentPane(tab);
                frame.setSize(520, 780);

                if (show) {
                    // 留窗给人工走查（含 hover 态）；切下拉里 127.0.0.1:8081 可看指引面板
                    frame.setLocation(120, 60);
                    frame.setVisible(true);
                    return;
                }

                // 离屏绘制：不经合成器，确定性出图
                frame.setUndecorated(true);
                frame.addNotify();
                frame.validate();
                Thread.sleep(800); // 等 QR 生成回调（图像加载异步）

                BufferedImage img = new BufferedImage(520, 780, BufferedImage.TYPE_INT_ARGB);
                java.awt.Graphics2D g = img.createGraphics();
                g.setColor(tab.getBackground());
                g.fillRect(0, 0, 520, 780);
                tab.paint(g);
                g.dispose();

                File out = new File("../../tmp/ui-preview-" + (guide ? "guide" : "qr") + ".png")
                        .getCanonicalFile();
                ImageIO.write(img, "png", out);
                System.out.println("截图已写: " + out);
                System.exit(0);
            } catch (Exception e) {
                e.printStackTrace();
                System.exit(1);
            }
        });
    }
}
