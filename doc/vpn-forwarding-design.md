# VPN 转发详细设计

> Android 与 iOS 两套原生实现**共同遵守**本文档的通道 API、CONNECT 转发条款与状态机。平台差异单独标注。

## 1. 数据流

```
App 流量 ── tun ──> libtun2socks(用户态TCP栈) ── SOCKS5 ──> 本地桥(127.0.0.1:10808)
                                                          │
            UDP/53 ── udpgw 协议 ──> DnsForwarder(127.0.0.1:7300)
                                                          │
                                              CONNECT host:port ──> Burp 上游
```

- tun2socks 只做 IP/TCP（含 TCP 重传、乱序），不认识 HTTP；向上游发 CONNECT 是本地桥的职责。
- 本地桥所有出网 socket 必须经 `VpnService.protect()`（Android）/ 系统隧道外发（iOS 扩展内天然不经隧道）。

## 2. Android VpnService.Builder 参数表

| 参数 | 值 | 说明 |
|---|---|---|
| session | `ProxyScan` | 系统 VPN 对话框显示名 |
| address | `10.10.10.2/32` | 私有段，避开常见热点段 |
| route | `0.0.0.0/0` | 全量 IPv4 进 tun（IPv6 不支持，见 known-limitations） |
| DNS | `223.5.5.5` | 公共 DNS 直连，**不过 Burp** |
| MTU | 1500 | |
| disallowed | 自身包名 | 防回环第一道保险 |

tun2socks 侧的 lwip 内网参数必须与 Builder 一致：`--netif-ipaddr 10.10.10.2 --netif-netmask 255.255.255.0`，经 JNI `Tun2Socks.run(tunFd, mtu, netifIp, netifMask, socksAddr, udpgwAddr)` 传入（`src/mobile/android/app/src/main/cpp/tun2socks_jni.c`）。

## 3. 通道 API（双端同面）

### 3.1 MethodChannel `proxy_scan/vpn`（Flutter → 原生）

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `start` | `{host: String, port: int}` | `{ok: true}` | 未授权时抛 `PlatformException(code: USER_DECLINED_CONSENT)` |
| `stop` | - | `{ok: true}` | 停止转发、撤 VPN、停服务 |
| `status` | - | `{state, upstream, error}` | 冷启动/重建时同步快照 |
| `prepare` | - | `{granted: bool}` | 仅弹系统 VPN 授权框预热 |
| `clearError` | - | `{ok: true}` | error 态复位 idle |

### 3.2 EventChannel `proxy_scan/vpn_events`（原生 → Flutter，1s 一帧）

```json
{"type":"state","state":"running","upstream":"192.168.1.10:8080"}
{"type":"stats","txBytes":12345,"rxBytes":67890,"activeConnections":3,"dnsQueries":12,"udpDropped":2}
{"type":"error","code":"UPSTREAM_UNREACHABLE","message":"连接上游超时"}
```

### 3.3 状态机

```
idle ──start──> preparing ──授权通过──> running ──stop──> stopping ──> idle
                     │拒绝                    │上游断开/内部错误
                     v                        v
              idle(授权拒绝)              error ──clearError──> idle
```

状态枚举：`idle / preparing / running / stopping / error`。

### 3.4 错误码

| code | 含义 |
|---|---|
| `USER_DECLINED_CONSENT` | 用户拒绝 VPN 授权 |
| `UPSTREAM_UNREACHABLE` | 连不上 Burp 上游（10s 超时） |
| `TUNNEL_HANDSHAKE_FAILED` | CONNECT 握手非 2xx/被重置 |
| `TUN_OPEN_FAILED` | VpnService establish 失败 |
| `INTERNAL` | 其他 |

## 4. CONNECT 转发条款（双端同规约）

1. 每个目标 TCP 连接，向上游发送：
   ```
   CONNECT host:port HTTP/1.1\r\nHost: host:port\r\n\r\n
   ```
   不携带其他头。
2. **严格解析响应头至 `\r\n\r\n`**；状态码必须 2xx。
3. 非 2xx 响应：**整体原样透传**给应用侧连接后关闭（应用拿到真实 407 等）。
4. **200 前缓冲**：按字节流解析头，越过边界后的残余字节**原样作为首包 payload 转发**，不得丢弃（服务器可能在状态行后立即开始 TLS ClientHello）。
5. 连接/读/写超时 10s → `UPSTREAM_UNREACHABLE`。
6. 双向 relay 8–16KB 缓冲；`read == -1` 时对向 `shutdownOutput()`（**半关闭传播**）；`ECONNRESET` 静默关闭双侧。
7. 字节计数（tx/rx）实时计入统计帧。

## 5. DNS / UDP

- Android：tun2socks `--udpgw-remote-server-addr 127.0.0.1:7300 --udpgw-transparent-dns`；badvpn 的 udpgw 走 **TCP** 且帧封装为 PacketProto（2B **小端**长度 + 载荷，badvpn 协议全小端；BAddr 端口为网络字节序直通），载荷 = `udpgw_header`(1B flags + 2B conid) + 地址(IPv4 4B IP + 2B 端口) + payload；flags：KEEPALIVE=1 / DNS=4 / IPV6=8。`DnsForwarder` 为 TCP 服务器：KEEPALIVE 原样回显；仅放行目标端口 53，payload 经 protected UDP 发 223.5.5.5:53，响应按原 conid/原始地址回填；其余 UDP 丢弃并 `udpDropped++`；多查询并发线程 + 写口加锁防帧交错。
- 注意：tun2socks 会把 udpgw 目标（127.0.0.1:7300）也作为普通目标走 SOCKS CONNECT，本地桥对**环回目标一律本机直连**，不经上游代理。
- iOS：NETunnelNetworkSettings 配公共 DNS；NEPacketTunnelFlow 的 UDP 读口同样仅处理 53。

## 6. 前台服务（Android，targetSdk 36 合规）

- `foregroundServiceType="specialUse"` + `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`；权限 `FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_SPECIAL_USE`、`POST_NOTIFICATIONS`、`INTERNET`。
- `START_STICKY`；通知 channel `vpn_service` 低重要性，内容显示"运行中 · 上游 host:port"。
- `onDestroy` 逆序清理：relay 线程中断 → 本地桥关闭 → `Tun2Socks.stop()` → tun fd close → 通知移除。

## 7. 清理顺序（stop 全链路）

1. EventChannel 推 `stopping`。
2. 关闭本地桥监听 socket（accept 循环退出，在途连接由 relay 完成或随 socket close 终止）。
3. `Tun2Socks.stop()`（内部 `terminate()`：quitting=1 + BReactor_Quit，TCP 定时器保证 ≤250ms 退出事件循环并释放 lwip/netif）。
4. `vpnInterface.close()`。
5. 停前台服务、释放 wake lock。
6. 推 `idle`。

## 8. 电量与休眠

- running 态持有 `PARTIAL_WAKE_LOCK`（引用计数），关屏不断连。
- 首次启动引导用户对本 App 关闭电池优化（跳系统设置页）；ColorOS 后台冻结另见 known-limitations。

## 9. iOS 对应关系（M5 实现时遵守）

| Android | iOS |
|---|---|
| VpnService + Builder | NEPacketTunnelProvider + NETunnelNetworkSettings |
| `protect(socket)` | 扩展进程内 socket 天然不经隧道 |
| tun2socks + BTAP_INIT_FD | NEPacketTunnelFlow（TCP 栈选型实现前评估 hev/mieru，禁自写完整 TCP 栈） |
| MethodChannel 桥 | FlutterMethodChannel（同方法名/参数/错误码） |
| NEVPNManager 不适用 | Runner 用 NEVPNManager 存配置 + `startVPNTunnel(options)` 下发上游 |

## 10. 流量统计

`VpnEngine` 内 `AtomicLong txBytes/rxBytes/dnsQueries/udpDropped` + `activeConnections`，1s 定时推 EventChannel；UI 状态页展示。
