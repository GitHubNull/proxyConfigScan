package com.proxyscan.burp;

import burp.api.montoya.logging.Logging;
import com.proxyscan.burp.qr.QrCodeGenerator;

import javax.swing.ImageIcon;
import javax.swing.JButton;
import javax.swing.JComboBox;
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
import java.util.List;
import java.util.Vector;
import java.util.function.Supplier;

/**
 * ProxyScan QR 标签页：自动读取 Burp Proxy 监听器 → 生成二维码供手机扫码。
 *
 * <p>主流程零配置：打开页签即调 {@link ProxyListenerDetector} 读运行中的 Burp 配置，
 * 监听器下拉里选一个即出码；{@code 0.0.0.0}/空绑定自动替换为本机局域网 IP。
 * 保留手填入口作为兜底（监听器读取失败时）。
 */
public class ProxyQrTab extends JPanel {

    private static final int QR_SIZE = 280;

    private final QrCodeGenerator generator = new QrCodeGenerator();
    private final Logging logging;
    private final Supplier<List<ProxyListenerDetector.Listener>> listenerSupplier;

    private final JComboBox<ProxyListenerDetector.Listener> listenerCombo = new JComboBox<>();
    private final JTextField hostField = new JTextField(detectLanIp(), 14);
    private final JTextField portField = new JTextField("8080", 5);
    private final JLabel qrLabel = new JLabel("正在读取 Burp 代理监听器…", JLabel.CENTER);
    private final JLabel uriLabel = new JLabel(" ", JLabel.CENTER);
    private final JLabel warningLabel = new JLabel(" ", JLabel.CENTER);

    public ProxyQrTab(Logging logging, Supplier<List<ProxyListenerDetector.Listener>> listenerSupplier) {
        this.logging = logging;
        this.listenerSupplier = listenerSupplier;
        setLayout(new BorderLayout(8, 8));

        listenerCombo.addActionListener(e -> onListenerSelected());
        JPanel auto = new JPanel(new FlowLayout(FlowLayout.LEFT));
        auto.add(new JLabel("Burp 监听器:"));
        auto.add(listenerCombo);
        JButton refresh = new JButton("重新读取");
        refresh.addActionListener(e -> loadListeners());
        auto.add(refresh);

        JPanel manual = new JPanel(new FlowLayout(FlowLayout.LEFT));
        manual.add(new JLabel("代理地址:"));
        manual.add(hostField);
        manual.add(new JLabel("端口:"));
        manual.add(portField);
        JButton generate = new JButton("生成二维码");
        generate.addActionListener(e -> regenerate());
        manual.add(generate);

        warningLabel.setForeground(new java.awt.Color(0xB00020));
        warningLabel.setFont(warningLabel.getFont().deriveFont(Font.PLAIN, 12f));

        JPanel top = new JPanel();
        top.setLayout(new javax.swing.BoxLayout(top, javax.swing.BoxLayout.Y_AXIS));
        top.add(auto);
        top.add(manual);
        top.add(warningLabel);
        add(top, BorderLayout.NORTH);

        JPanel qrPanel = new JPanel(new BorderLayout(4, 4));
        uriLabel.setFont(uriLabel.getFont().deriveFont(Font.BOLD, 14f));
        qrPanel.add(uriLabel, BorderLayout.NORTH);
        qrPanel.add(qrLabel, BorderLayout.CENTER);
        add(qrPanel, BorderLayout.CENTER);

        loadListeners();
    }

    private void loadListeners() {
        List<ProxyListenerDetector.Listener> listeners;
        try {
            listeners = listenerSupplier.get();
        } catch (Exception e) {
            listeners = List.of();
            logging.logToError("ProxyScan QR 读取监听器异常：" + e.getMessage());
        }
        listenerCombo.setModel(new javax.swing.DefaultComboBoxModel<>(new Vector<>(listeners)));
        if (listeners.isEmpty()) {
            listenerCombo.setEnabled(false);
            qrLabel.setIcon(null);
            qrLabel.setText("未读取到 Burp 代理监听器，请检查 Burp 配置或手填下方地址");
        } else {
            listenerCombo.setEnabled(true);
            // 默认选中第一个非回环监听器
            int best = 0;
            for (int i = 0; i < listeners.size(); i++) {
                if (!listeners.get(i).isLoopback()) { best = i; break; }
            }
            listenerCombo.setSelectedIndex(best);
        }
    }

    private void onListenerSelected() {
        ProxyListenerDetector.Listener listener = (ProxyListenerDetector.Listener) listenerCombo.getSelectedItem();
        if (listener == null) return;
        String host = listener.isAnyInterface() ? detectLanIp() : listener.address();
        hostField.setText(host);
        portField.setText(String.valueOf(listener.port()));
        if (listener.isAnyInterface()) {
            warningLabel.setText("监听器绑定全部接口，二维码已填本机局域网 IP " + host + "（手机须同网段）");
        } else if (listener.isLoopback()) {
            warningLabel.setText("注意：" + listener.address() + " 仅限本机访问，手机扫码后连不上，请让 Burp 绑定全部接口或局域网 IP");
        } else {
            warningLabel.setText(" ");
        }
        regenerate();
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
            java.util.Enumeration<NetworkInterface> ifaces = NetworkInterface.getNetworkInterfaces();
            while (ifaces != null && ifaces.hasMoreElements()) {
                NetworkInterface iface = ifaces.nextElement();
                if (!iface.isUp() || iface.isLoopback()) continue;
                java.util.Enumeration<InetAddress> addrs = iface.getInetAddresses();
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
