package com.proxyscan.burp;

import burp.api.montoya.logging.Logging;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Stream;

/**
 * 进程反查：从系统实际监听的 TCP 端口反推出 Burp 的代理监听器。
 *
 * <p>思路（用户提出）：扫描系统监听端口 → 反查所属进程 → 按命令行特征
 * （含 {@code burpsuite}）确认是 Burp → 得到真实绑定地址与端口。
 * 反映的是"实际在监听什么"，比读配置更可靠。
 *
 * <p>平台路径：Linux 走 /proc（socket inode 精确归属，无需 root，同用户即可）；
 * 其他平台回退 {@code netstat -ano} 按 pid 过滤。
 */
public class BurpProcessScanner {

    private static final String BURP_CMDLINE_MARKER = "burpsuite";

    private final Logging logging;

    public BurpProcessScanner(Logging logging) {
        this.logging = logging;
    }

    /** 反查 Burp 进程实际监听的 TCP 端口；查不到返回空表。 */
    public List<ProxyListenerDetector.Listener> scan() {
        List<Long> burpPids = findBurpPids();
        if (burpPids.isEmpty()) {
            logging.logToError("ProxyScan QR 未找到 Burp 进程（命令行不含 " + BURP_CMDLINE_MARKER + "）");
            return List.of();
        }
        if (System.getProperty("os.name", "").toLowerCase().contains("linux")) {
            return scanViaProc(burpPids);
        }
        return scanViaNetstat(burpPids);
    }

    /** 命令行含 burpsuite 的存活进程 pid。 */
    static List<Long> findBurpPids() {
        List<Long> pids = new ArrayList<>();
        ProcessHandle.allProcesses().forEach(ph ->
                ph.info().commandLine()
                        .map(c -> c.toLowerCase().contains(BURP_CMDLINE_MARKER))
                        .filter(Boolean::booleanValue)
                        .ifPresent(b -> pids.add(ph.pid())));
        return pids;
    }

    /** Linux：/proc/net/tcp{,6} 全部监听 socket 的 inode → 地址端口表。 */
    static Map<String, ProxyListenerDetector.Listener> parseProcNetTcp(String content, boolean ipv6) {
        Map<String, ProxyListenerDetector.Listener> inodes = new LinkedHashMap<>();
        String[] lines = content.split("\n");
        for (int i = 1; i < lines.length; i++) { // 首行是表头
            String[] cols = lines[i].trim().split("\\s+");
            if (cols.length < 10) continue;
            String[] local = cols[1].split(":");
            if (cols[3].equals("0A")) { // 0A = LISTEN
                inodes.put(cols[9], new ProxyListenerDetector.Listener(
                        decodeIp(local[0], ipv6), Integer.parseInt(local[1], 16)));
            }
        }
        return inodes;
    }

    /** /proc/net/tcp 的地址是十六进制小端：0100007F → 127.0.0.1。 */
    static String decodeIp(String hex, boolean ipv6) {
        if (!ipv6) {
            long v = Long.parseLong(hex, 16);
            return ((v >> 0) & 0xff) + "." + ((v >> 8) & 0xff) + "." + ((v >> 16) & 0xff) + "." + ((v >> 24) & 0xff);
        }
        // IPv6：32 个十六进制字符，4 字节一组小端；仅处理全 0 前导（::/::1/映射 v4）的常见形态
        String compact = hex.replaceFirst("^0+", "");
        if (compact.isEmpty() || hex.chars().allMatch(c -> c == '0')) return "::";
        if (hex.startsWith("00000000000000000000000001000000")) return "::1";
        // v4 映射：...FFFF:0101A8C0 形态（如 ::ffff:192.168.x.x，后 4 字节小端）
        if (hex.toUpperCase().startsWith("0000000000000000FFFF0000")) {
            return decodeIp(hex.substring(24), false);
        }
        return ipv6 ? "::" : "0.0.0.0"; // 复杂 IPv6 形态不在二维码场景出现，保守回退
    }

    private List<ProxyListenerDetector.Listener> scanViaProc(List<Long> burpPids) {
        try {
            Map<String, ProxyListenerDetector.Listener> all = new LinkedHashMap<>();
            all.putAll(parseProcNetTcp(Files.readString(Path.of("/proc/net/tcp")), false));
            all.putAll(parseProcNetTcp(Files.readString(Path.of("/proc/net/tcp6")), true));

            Map<ProxyListenerDetector.Listener, Boolean> found = new LinkedHashMap<>();
            for (long pid : burpPids) {
                Path fdDir = Path.of("/proc", String.valueOf(pid), "fd");
                try (Stream<Path> fds = Files.list(fdDir)) {
                    for (Path fd : fds.toList()) {
                        Optional<String> target = Optional.ofNullable(Files.readSymbolicLink(fd)).map(Path::toString);
                        if (target.isPresent() && target.get().startsWith("socket:[")) {
                            String inode = target.get().substring("socket:[".length(), target.get().length() - 1);
                            ProxyListenerDetector.Listener l = all.get(inode);
                            if (l != null) found.put(l, true);
                        }
                    }
                } catch (IOException e) {
                    logging.logToError("ProxyScan QR 读取 /proc/" + pid + "/fd 失败：" + e.getMessage());
                }
            }
            return List.copyOf(found.keySet());
        } catch (IOException e) {
            logging.logToError("ProxyScan QR 读取 /proc/net/tcp 失败：" + e.getMessage());
            return List.of();
        }
    }

    /** 非 Linux：netstat -ano 输出按 Burp pid 过滤。供单测直调的逐行解析见 [parseNetstatLine]。 */
    private List<ProxyListenerDetector.Listener> scanViaNetstat(List<Long> burpPids) {
        try {
            Process p = new ProcessBuilder("netstat", "-ano").redirectErrorStream(true).start();
            String out = new String(p.getInputStream().readAllBytes());
            p.waitFor();
            List<ProxyListenerDetector.Listener> result = new ArrayList<>();
            for (String line : out.split("\n")) {
                ProxyListenerDetector.Listener l = parseNetstatLine(line, burpPids);
                if (l != null && !result.contains(l)) result.add(l);
            }
            return result;
        } catch (IOException | InterruptedException e) {
            logging.logToError("ProxyScan QR netstat 反查失败：" + e.getMessage());
            return List.of();
        }
    }

    /**
     * 解析 {@code netstat -ano} 一行：TCP 监听行且 pid 属于 Burp 才返回。
     * 形如 {@code TCP    0.0.0.0:8080    0.0.0.0:0    LISTENING    7680}。
     */
    static ProxyListenerDetector.Listener parseNetstatLine(String line, List<Long> burpPids) {
        String[] cols = line.trim().split("\\s+");
        if (cols.length < 5 || !cols[0].equalsIgnoreCase("TCP")) return null;
        if (!cols[3].equalsIgnoreCase("LISTENING") && !cols[3].equalsIgnoreCase("LISTEN")) return null;
        long pid;
        try {
            pid = Long.parseLong(cols[cols.length - 1]);
        } catch (NumberFormatException e) {
            return null;
        }
        if (!burpPids.contains(pid)) return null;
        String local = cols[1];
        int idx = local.lastIndexOf(':');
        if (idx <= 0) return null;
        return new ProxyListenerDetector.Listener(local.substring(0, idx), Integer.parseInt(local.substring(idx + 1)));
    }
}
