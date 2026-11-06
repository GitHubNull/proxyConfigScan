package com.proxyscan.burp;

import burp.api.montoya.logging.Logging;
import com.proxyscan.burp.qr.QrCodeGenerator;

import javax.swing.ImageIcon;
import javax.swing.JButton;
import javax.swing.JComboBox;
import javax.swing.JLabel;
import javax.swing.JPanel;
import javax.swing.JTextField;
import javax.swing.SwingConstants;
import java.awt.BorderLayout;
import java.awt.CardLayout;
import java.awt.Component;
import java.awt.Dimension;
import java.awt.FlowLayout;
import java.awt.Font;
import java.awt.Image;
import java.awt.Toolkit;
import java.awt.datatransfer.StringSelection;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.List;
import java.util.Vector;
import java.util.function.Supplier;

import static com.proxyscan.burp.Ui.ACCENT;
import static com.proxyscan.burp.Ui.DANGER;
import static com.proxyscan.burp.Ui.ELEVATED;
import static com.proxyscan.burp.Ui.FG;
import static com.proxyscan.burp.Ui.MUTED;

/**
 * ProxyScan QR 标签页：自动读取 Burp Proxy 监听器 → 生成二维码供手机扫码。
 *
 * <p>主流程零配置：打开页签即读运行中的 Burp 监听器，下拉选一个即出码；
 * {@code 0.0.0.0}/空绑定自动替换为本机局域网 IP。回环绑定不出码——手机扫码后
 * 无法抓包，切换为修复指引面板（改绑局域网 IP 的步骤 + 本机 IP 复制）。
 * 保留手填入口作为兜底（监听器读取失败时）。
 *
 * <p>视觉：跟随 Burp（FlatLaf）主题，品牌橙主按钮 + 圆角卡片分区（{@link Ui}）。
 */
public class ProxyQrTab extends JPanel {

    private static final int QR_SIZE = 280;

    private final QrCodeGenerator generator = new QrCodeGenerator();
    private final Logging logging;
    private final Supplier<List<ProxyListenerDetector.Listener>> listenerSupplier;

    private final JComboBox<ProxyListenerDetector.Listener> listenerCombo = new JComboBox<>();
    private final JTextField hostField = Ui.field(14);
    private final JTextField portField = Ui.field(5);
    private final JLabel qrLabel = new JLabel("正在读取 Burp 代理监听器…", SwingConstants.CENTER);
    private final JLabel uriLabel = new JLabel(" ", SwingConstants.CENTER);
    private final JLabel warningLabel = new JLabel(" ", SwingConstants.CENTER);

    private final CardLayout centerCards = new CardLayout();
    private final JPanel centerPanel = new JPanel(centerCards);
    private final JPanel qrCardPanel;
    private final JPanel loopbackGuidePanel = buildLoopbackGuidePanel();

    public ProxyQrTab(Logging logging, Supplier<List<ProxyListenerDetector.Listener>> listenerSupplier) {
        this.logging = logging;
        this.listenerSupplier = listenerSupplier;
        setLayout(new BorderLayout(0, 12));
        setBorder(javax.swing.BorderFactory.createEmptyBorder(18, 20, 14, 20));
        setBackground(Ui.BG);

        // ---- 头部：标题 + 副标题 ----
        JPanel header = Ui.column();
        header.add(Ui.title("ProxyScan QR"));
        header.add(Ui.vGap(4));
        header.add(Ui.muted("手机扫码自动完成代理配置，接入 Burp 抓包"));

        // ---- 监听器卡片 ----
        listenerCombo.addActionListener(e -> onListenerSelected());
        styleCombo(listenerCombo);
        JButton refresh = Ui.ghostButton("重新读取");
        refresh.addActionListener(e -> loadListeners());

        JPanel listenerCard = Ui.card(new BorderLayout());
        listenerCard.setBorder(padded(12));
        JPanel listenerRow = Ui.row(new BorderLayout(8, 0));
        listenerRow.add(listenerCombo, BorderLayout.CENTER);
        listenerRow.add(refresh, BorderLayout.EAST);
        listenerCard.add(sectioned("监听器", listenerRow), BorderLayout.CENTER);

        // ---- 手动配置卡片（兜底） ----
        JButton generate = Ui.primaryButton("生成二维码");
        generate.addActionListener(e -> regenerate());
        hostField.setText(detectLanIp());
        portField.setText("8080");

        JPanel manualCard = Ui.card(new BorderLayout());
        manualCard.setBorder(padded(12));
        JPanel manualRow = Ui.row(new FlowLayout(FlowLayout.LEFT, 8, 0));
        manualRow.add(Ui.muted("地址"));
        hostField.setPreferredSize(new Dimension(hostField.getPreferredSize().width, 30));
        manualRow.add(hostField);
        manualRow.add(Ui.muted("端口"));
        portField.setPreferredSize(new Dimension(portField.getPreferredSize().width, 30));
        manualRow.add(portField);
        manualRow.add(generate);
        manualCard.add(sectioned("手动配置", manualRow), BorderLayout.CENTER);

        // ---- 警告条 ----
        warningLabel.setFont(warningLabel.getFont().deriveFont(Font.PLAIN, 12f));

        // ---- 顶部组装 ----
        JPanel top = Ui.column();
        top.add(header);
        top.add(Ui.vGap(14));
        top.add(listenerCard);
        top.add(Ui.vGap(10));
        top.add(manualCard);
        top.add(Ui.vGap(8));
        top.add(warningLabel);
        add(top, BorderLayout.NORTH);

        // ---- 中部：二维码卡片 / 回环指引卡片 ----
        qrCardPanel = buildQrCard();
        centerPanel.setOpaque(false);
        centerPanel.add(qrCardPanel, "qr");
        centerPanel.add(loopbackGuidePanel, "guide");
        add(centerPanel, BorderLayout.CENTER);

        loadListeners();
    }

    /** 分区标题 + 内容的两行结构。 */
    private static JPanel sectioned(String title, Component content) {
        JPanel p = Ui.column();
        p.add(Ui.section(title));
        p.add(Ui.vGap(8));
        p.add(content);
        return p;
    }

    /** 卡片圆角描边 + 内部留白。 */
    private static javax.swing.border.Border padded(int inset) {
        return new javax.swing.border.CompoundBorder(
                new Ui.RoundBorder(Ui.BORDER),
                javax.swing.BorderFactory.createEmptyBorder(inset, inset, inset, inset));
    }

    private static void styleCombo(JComboBox<?> combo) {
        combo.setBackground(ELEVATED);
        combo.setForeground(FG);
        combo.setBorder(new Ui.RoundBorder(Ui.BORDER));
        combo.setPreferredSize(new Dimension(combo.getPreferredSize().width, 30));
    }

    /** 二维码卡片：白底衬码 + 下方 URI。 */
    private JPanel buildQrCard() {
        JPanel card = Ui.card(new BorderLayout(0, 10));
        card.setBorder(padded(16));

        JPanel qrPad = new JPanel(new BorderLayout());
        qrPad.setOpaque(false);
        qrLabel.setForeground(MUTED);
        qrLabel.setFont(qrLabel.getFont().deriveFont(Font.PLAIN, 13f));
        qrPad.add(qrLabel, BorderLayout.CENTER);
        card.add(qrPad, BorderLayout.CENTER);

        uriLabel.setForeground(FG);
        uriLabel.setFont(uriLabel.getFont().deriveFont(Font.BOLD, 14f));
        card.add(uriLabel, BorderLayout.SOUTH);
        return card;
    }

    /** 回环选中时展示的修复指引面板（替代二维码）。 */
    private JPanel buildLoopbackGuidePanel() {
        JPanel card = Ui.card(new BorderLayout(0, 12));
        card.setBorder(padded(16));

        JPanel body = Ui.column();

        JLabel headline = new JLabel("该监听器仅本机可达，手机扫码后无法抓包");
        headline.setForeground(DANGER);
        headline.setFont(headline.getFont().deriveFont(Font.BOLD, 14f));
        body.add(headline);
        body.add(Ui.vGap(6));
        body.add(Ui.muted("在 Burp 中把监听地址改绑到局域网，步骤："));
        body.add(Ui.vGap(10));
        body.add(guideStep("1", "Settings → Proxy → Proxy settings"));
        body.add(Ui.vGap(6));
        body.add(guideStep("2", "编辑对应 listener → Bind to address"));
        body.add(Ui.vGap(6));
        body.add(guideStep("3", "选 Specific address，填入下方本机局域网 IP"));
        body.add(Ui.vGap(6));
        body.add(guideStep("4", "保存后回本页签点「重新读取」"));
        body.add(Ui.vGap(4));
        body.add(Ui.muted("或直接把 Bind to address 改为 All interfaces"));
        body.add(Ui.vGap(16));

        // 本机 IP + 复制
        String lanIp = detectLanIp();
        JTextField ipField = Ui.field(14);
        ipField.setText(lanIp);
        ipField.setEditable(false);
        ipField.setPreferredSize(new Dimension(ipField.getPreferredSize().width, 30));
        JButton copy = Ui.ghostButton("复制 IP");
        copy.addActionListener(e -> {
            Toolkit.getDefaultToolkit().getSystemClipboard()
                    .setContents(new StringSelection(ipField.getText()), null);
            copy.setText("已复制");
            javax.swing.Timer timer = new javax.swing.Timer(2000, ev -> copy.setText("复制 IP"));
            timer.setRepeats(false);
            timer.start();
        });
        JPanel ipRow = Ui.row(new FlowLayout(FlowLayout.LEFT, 8, 0));
        ipRow.add(Ui.muted("本机局域网 IP"));
        ipRow.add(ipField);
        ipRow.add(copy);
        body.add(ipRow);
        card.add(body, BorderLayout.CENTER);
        return card;
    }

    private static JPanel guideStep(String num, String text) {
        JPanel row = Ui.row(new BorderLayout(10, 0));
        JLabel n = new JLabel(num, SwingConstants.CENTER) {
            @Override
            protected void paintComponent(java.awt.Graphics g) {
                java.awt.Graphics2D g2 = (java.awt.Graphics2D) g.create();
                g2.setRenderingHint(java.awt.RenderingHints.KEY_ANTIALIASING,
                        java.awt.RenderingHints.VALUE_ANTIALIAS_ON);
                g2.setColor(ACCENT);
                g2.fillRoundRect(0, 0, getWidth() - 1, getHeight() - 1, 10, 10);
                g2.dispose();
                super.paintComponent(g);
            }
        };
        n.setOpaque(false);
        n.setPreferredSize(new Dimension(22, 22));
        n.setForeground(java.awt.Color.WHITE);
        n.setFont(n.getFont().deriveFont(Font.BOLD, 12f));
        row.add(n, BorderLayout.WEST);
        JLabel t = new JLabel(text);
        t.setForeground(FG);
        row.add(t, BorderLayout.CENTER);
        return row;
    }

    private void showQrOrGuide(boolean guide) {
        centerCards.show(centerPanel, guide ? "guide" : "qr");
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
        showQrOrGuide(false);
        if (listeners.isEmpty()) {
            listenerCombo.setEnabled(false);
            qrLabel.setIcon(null);
            qrLabel.setText("未读取到 Burp 代理监听器，请检查 Burp 配置或手填上方地址");
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
        if (listener.isLoopback()) {
            setWarning(listener.address() + " 仅本机可达，手机扫码后无法抓包", DANGER);
            showQrOrGuide(true); // 回环不出码，给修复指引
        } else {
            showQrOrGuide(false);
            if (listener.isAnyInterface()) {
                setWarning("监听器绑定全部接口，二维码已填本机局域网 IP " + host + "（手机须同网段）", MUTED);
            } else {
                setWarning(" ", null);
            }
            regenerate();
        }
    }

    private void setWarning(String text, java.awt.Color color) {
        warningLabel.setText(text);
        warningLabel.setForeground(color != null ? color : MUTED);
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

        if (ProxyListenerDetector.isLoopbackAddress(host)) {
            setWarning(host + " 是回环地址，手机扫码后无法抓包，请改用局域网 IP", DANGER);
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
