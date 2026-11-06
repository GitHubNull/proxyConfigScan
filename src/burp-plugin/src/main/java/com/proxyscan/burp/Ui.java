package com.proxyscan.burp;

import javax.swing.BoxLayout;
import javax.swing.JButton;
import javax.swing.JComponent;
import javax.swing.JLabel;
import javax.swing.JPanel;
import javax.swing.JTextField;
import javax.swing.UIManager;
import javax.swing.border.AbstractBorder;
import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.Component;
import java.awt.Container;
import java.awt.Cursor;
import java.awt.Dimension;
import java.awt.Font;
import java.awt.Graphics;
import java.awt.Graphics2D;
import java.awt.Insets;
import java.awt.RenderingHints;
import java.awt.event.FocusAdapter;
import java.awt.event.FocusEvent;

/**
 * Swing 质感组件集：配色跟随 Burp（FlatLaf）主题，统一圆角卡片 / 按钮 / 输入框。
 * 全部静态工厂，{@link ProxyQrTab} 专用。
 */
final class Ui {

    /** Burp 品牌橙：主按钮与强调色。 */
    static final Color ACCENT = new Color(0xFF6633);
    static final Color DANGER = new Color(0xE05561);
    static final Color WARN = new Color(0xE8A33D);

    static final Color BG = def("Panel.background", 0x26282B);
    static final Color FG = def("Label.foreground", 0xD7DADE);
    static final boolean DARK = luminance(BG) < 0.5;
    /** 卡片底：比页面底略浅（暗色）/略深（亮色）。 */
    static final Color CARD = shift(BG, DARK ? 1.10 : 0.94);
    /** 卡片内控件底/悬停底。 */
    static final Color ELEVATED = shift(BG, DARK ? 1.18 : 0.90);
    static final Color BORDER = shift(BG, DARK ? 1.30 : 0.84);
    static final Color MUTED = mix(FG, BG, 0.55);

    private Ui() {}

    private static Color def(String key, int rgb) {
        Color c = UIManager.getColor(key);
        return c != null ? c : new Color(rgb);
    }

    private static double luminance(Color c) {
        return (0.299 * c.getRed() + 0.587 * c.getGreen() + 0.114 * c.getBlue()) / 255;
    }

    /** 向背景色方向混合 ratio（0=纯 fg，1=纯 bg）。 */
    static Color mix(Color fg, Color bg, double ratio) {
        int r = (int) (fg.getRed() * (1 - ratio) + bg.getRed() * ratio);
        int g = (int) (fg.getGreen() * (1 - ratio) + bg.getGreen() * ratio);
        int b = (int) (fg.getBlue() * (1 - ratio) + bg.getBlue() * ratio);
        return new Color(r, g, b);
    }

    private static Color shift(Color c, double f) {
        return new Color(
                (int) Math.min(255, c.getRed() * f),
                (int) Math.min(255, c.getGreen() * f),
                (int) Math.min(255, c.getBlue() * f));
    }

    // ---------- 文本 ----------

    /** 页面大标题。 */
    static JLabel title(String text) {
        JLabel l = new JLabel(text);
        l.setFont(l.getFont().deriveFont(Font.BOLD, 16f));
        l.setForeground(FG);
        return l;
    }

    /** 副标题 / 说明文字。 */
    static JLabel muted(String text) {
        JLabel l = new JLabel(text);
        l.setForeground(MUTED);
        return l;
    }

    /** 分区小标题（监听器 / 手动配置）。 */
    static JLabel section(String text) {
        JLabel l = new JLabel(text);
        l.setFont(l.getFont().deriveFont(Font.BOLD, 11f));
        l.setForeground(MUTED);
        return l;
    }

    // ---------- 卡片 ----------

    /** 圆角卡片容器：底色 + 细边，子布局交给调用方。 */
    static JPanel card(java.awt.LayoutManager layout) {
        JPanel p = new JPanel(layout) {
            @Override
            protected void paintComponent(Graphics g) {
                Graphics2D g2 = (Graphics2D) g.create();
                g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
                g2.setColor(CARD);
                g2.fillRoundRect(0, 0, getWidth() - 1, getHeight() - 1, 10, 10);
                g2.setColor(BORDER);
                g2.drawRoundRect(0, 0, getWidth() - 1, getHeight() - 1, 10, 10);
                g2.dispose();
            }
        };
        p.setOpaque(false);
        return p;
    }

    // ---------- 按钮 ----------

    static JButton primaryButton(String text) {
        return styledButton(text, true);
    }

    static JButton ghostButton(String text) {
        return styledButton(text, false);
    }

    private static JButton styledButton(String text, boolean primary) {
        JButton b = new JButton(text) {
            @Override
            protected void paintComponent(Graphics g) {
                Graphics2D g2 = (Graphics2D) g.create();
                g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
                Color bg = null;
                if (isEnabled()) {
                    if (getModel().isPressed()) {
                        bg = primary ? ACCENT.darker() : mix(ELEVATED, BG, 0.35);
                    } else if (getModel().isRollover()) {
                        bg = primary ? shift(ACCENT, 1.12) : ELEVATED;
                    } else if (primary) {
                        bg = ACCENT;
                    }
                } else {
                    bg = primary ? mix(ACCENT, BG, 0.65) : null;
                }
                if (bg != null) {
                    g2.setColor(bg);
                    g2.fillRoundRect(0, 0, getWidth() - 1, getHeight() - 1, 7, 7);
                }
                g2.dispose();
                super.paintComponent(g);
            }
        };
        b.setContentAreaFilled(false);
        b.setBorderPainted(false);
        b.setFocusPainted(false);
        b.setOpaque(false);
        b.setCursor(Cursor.getPredefinedCursor(Cursor.HAND_CURSOR));
        b.setForeground(primary ? Color.WHITE : FG);
        b.setFont(b.getFont().deriveFont(Font.PLAIN, 12f));
        // 统一高度 + 水平内边距
        b.setBorder(new AbstractBorder() {
            @Override
            public Insets getBorderInsets(Component c) {
                return new Insets(6, 14, 6, 14);
            }
        });
        b.setPreferredSize(new Dimension(
                b.getPreferredSize().width, 30));
        return b;
    }

    // ---------- 输入框 ----------

    /** 圆角输入框：聚焦时描边转品牌橙。 */
    static JTextField field(int cols) {
        JTextField f = new JTextField(cols);
        f.setOpaque(false);
        f.setForeground(FG);
        f.setCaretColor(FG);
        f.setBorder(new RoundBorder(BORDER));
        f.addFocusListener(new FocusAdapter() {
            @Override
            public void focusGained(FocusEvent e) {
                f.setBorder(new RoundBorder(ACCENT));
            }

            @Override
            public void focusLost(FocusEvent e) {
                f.setBorder(new RoundBorder(BORDER));
            }
        });
        return f;
    }

    /** 圆角描边（卡片内控件用）。 */
    static final class RoundBorder extends AbstractBorder {
        private final Color color;

        RoundBorder(Color color) {
            this.color = color;
        }

        @Override
        public void paintBorder(Component c, Graphics g, int x, int y, int w, int h) {
            Graphics2D g2 = (Graphics2D) g.create();
            g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
            g2.setColor(color);
            g2.setStroke(new BasicStroke(1f));
            g2.drawRoundRect(x, y, w - 1, h - 1, 7, 7);
            g2.dispose();
        }

        @Override
        public Insets getBorderInsets(Component c) {
            return new Insets(6, 10, 6, 10);
        }
    }

    /** 纵向 BoxLayout 里靠左对齐（JLabel/JPanel 默认居中）。 */
    static <T extends Component> T left(T c) {
        if (c instanceof JComponent jc) {
            jc.setAlignmentX(JComponent.LEFT_ALIGNMENT);
        }
        return c;
    }

    /**
     * 纵向流式容器：子件全宽拉伸、按序从上到下、顶部对齐。
     * 不用 BoxLayout——它对「宽度无界」的判定依赖 maximumSizeSet 标志，
     * 匿名覆盖 getMaximumSize 不生效，子件会被居中收缩。
     */
    static JPanel column() {
        JPanel p = new JPanel(new VerticalLayout());
        p.setOpaque(false);
        return p;
    }

    /** 极简纵向布局：所有可见子件取首选高度、横向铺满。 */
    static final class VerticalLayout implements java.awt.LayoutManager {
        private static final int GAP = 0;

        @Override
        public void addLayoutComponent(String name, Component comp) {}

        @Override
        public void removeLayoutComponent(Component comp) {}

        @Override
        public Dimension preferredLayoutSize(Container parent) {
            Insets in = parent.getInsets();
            int w = 0;
            int h = in.top;
            for (Component c : parent.getComponents()) {
                if (!c.isVisible()) continue;
                Dimension d = c.getPreferredSize();
                w = Math.max(w, d.width);
                h += d.height + GAP;
            }
            h = h > in.top ? h - GAP + in.bottom : h + in.bottom;
            return new Dimension(w + in.left + in.right, h);
        }

        @Override
        public Dimension minimumLayoutSize(Container parent) {
            return preferredLayoutSize(parent);
        }

        @Override
        public void layoutContainer(Container parent) {
            Insets in = parent.getInsets();
            int w = parent.getWidth() - in.left - in.right;
            int y = in.top;
            for (Component c : parent.getComponents()) {
                if (!c.isVisible()) continue;
                Dimension d = c.getPreferredSize();
                c.setBounds(in.left, y, w, d.height);
                y += d.height + GAP;
            }
        }
    }

    /** 横向行容器：纵向不占多余空间（BoxLayout 会把拉伸空间分给高度无界的行）。 */
    static JPanel row(java.awt.LayoutManager lm) {
        JPanel p = new JPanel(lm) {
            @Override
            public Dimension getMaximumSize() {
                return getPreferredSize();
            }
        };
        p.setOpaque(false);
        return p;
    }

    /** 组件间垂直间距。 */
    static JComponent vGap(int h) {
        JComponent c = new JComponent() {};
        c.setPreferredSize(new Dimension(0, h));
        c.setMaximumSize(new Dimension(Integer.MAX_VALUE, h));
        return c;
    }

    static Font font(JComponent c, int style, float size) {
        return c.getFont().deriveFont(style, size);
    }
}
