package com.proxyscan.burp;

import burp.api.montoya.logging.Logging;
import com.proxyscan.burp.qr.QrCodeGenerator;

import javax.swing.ImageIcon;
import javax.swing.JButton;
import javax.swing.JLabel;
import javax.swing.JPanel;
import javax.swing.JTextField;
import java.awt.BorderLayout;
import java.awt.FlowLayout;
import java.awt.Font;
import java.awt.Image;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.Enumeration;

/**
 * ProxyScan QR 标签页：填 host:port → 生成二维码供手机扫码。
 *
 * <p>montoya-api 无枚举 Burp Proxy 监听器的接口（2026.7 全包核实），
 * 故由用户对照 Burp Proxy settings 填入；host 默认自动探测本机局域网 IPv4。
 */
public class ProxyQrTab extends JPanel {

    private static final int QR_SIZE = 280;

    private final QrCodeGenerator generator = new QrCodeGenerator();
    private final Logging logging;

    private final JTextField hostField = new JTextField(detectLanIp(), 14);
    private final JTextField portField = new JTextField("8080", 5);
    private final JLabel qrLabel = new JLabel("点击「生成二维码」", JLabel.CENTER);
    private final JLabel uriLabel = new JLabel(" ", JLabel.CENTER);
    private final JLabel warningLabel = new JLabel(" ", JLabel.CENTER);

    public ProxyQrTab(Logging logging) {
        this.logging = logging;
        setLayout(new BorderLayout(8, 8));

        JPanel form = new JPanel(new FlowLayout(FlowLayout.LEFT));
        form.add(new JLabel("代理地址:"));
        form.add(hostField);
        form.add(new JLabel("端口:"));
        form.add(portField);
        JButton generate = new JButton("生成二维码");
        generate.addActionListener(e -> regenerate());
        form.add(generate);
        add(form, BorderLayout.NORTH);

        warningLabel.setForeground(new java.awt.Color(0xB00020));
        Font small = warningLabel.getFont().deriveFont(Font.PLAIN, 12f);
        warningLabel.setFont(small);
        add(warningLabel, BorderLayout.SOUTH);

        JPanel center = new JPanel(new BorderLayout(4, 4));
        uriLabel.setFont(uriLabel.getFont().deriveFont(Font.BOLD, 14f));
        center.add(uriLabel, BorderLayout.NORTH);
        center.add(qrLabel, BorderLayout.CENTER);
        add(center, BorderLayout.CENTER);
    }

    private void regenerate() {
        String host = hostField.getText().trim();
        int port;
        try {
            port = Integer.parseInt(portField.getText().trim());
        } catch (NumberFormatException e) {
            showError("端口必须是数字");
            return;
        }
        if (host.isEmpty()) {
            showError("代理地址不能为空");
            return;
        }
        if (port < 1 || port > 65535) {
            showError("端口需在 1-65535 之间");
            return;
        }

        boolean loopback = host.equals("127.0.0.1") || host.equals("::1") || host.equalsIgnoreCase("localhost");
        if (loopback) {
            warningLabel.setText("注意：127.0.0.1 仅限本机访问，手机扫码后连不上，请填本机局域网 IP（Burp Proxy settings 里绑定的地址）");
        } else {
            warningLabel.setText(" ");
        }

        String uri = "http://" + host + ":" + port;
        try {
            byte[] png = generator.toPng(uri, QR_SIZE);
            ImageIcon icon = new ImageIcon(png);
            icon.setImage(icon.getImage().getScaledInstance(QR_SIZE, QR_SIZE, Image.SCALE_SMOOTH));
            qrLabel.setIcon(icon);
            qrLabel.setText(null);
            uriLabel.setText(uri);
            logging.logToOutput("ProxyScan QR 已生成：" + uri);
        } catch (QrCodeGenerator.QrGenerateException e) {
            showError(e.getMessage());
        }
    }

    private void showError(String message) {
        qrLabel.setIcon(null);
        qrLabel.setText(message);
        uriLabel.setText(" ");
        logging.logToError("ProxyScan QR 生成失败：" + message);
    }

    /** 自动探测本机第一个非回环 IPv4 私网地址，失败回退 127.0.0.1。 */
    private static String detectLanIp() {
        try {
            Enumeration<NetworkInterface> ifaces = NetworkInterface.getNetworkInterfaces();
            while (ifaces != null && ifaces.hasMoreElements()) {
                NetworkInterface iface = ifaces.nextElement();
                if (!iface.isUp() || iface.isLoopback()) continue;
                Enumeration<InetAddress> addrs = iface.getInetAddresses();
                while (addrs.hasMoreElements()) {
                    InetAddress addr = addrs.nextElement();
                    if (addr instanceof Inet4Address inet4 && !inet4.isLoopbackAddress() && inet4.isSiteLocalAddress()) {
                        return inet4.getHostAddress();
                    }
                }
            }
        } catch (Exception ignored) {
            // 探测失败仅影响默认值，用户可手填
        }
        return "127.0.0.1";
    }
}
