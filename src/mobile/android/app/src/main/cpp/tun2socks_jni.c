#include <jni.h>
#include <pthread.h>
#include <string.h>
#include <errno.h>
#include <time.h>

/*
 * ProxyScan tun2socks JNI 包装器。
 *
 * 通过 #include 获得 tun2socks.c 的静态符号（main 不会被调用），
 * 用 BTap_Init2 的 BTAP_INIT_FD 路径接收 VpnService 建立的 tun fd，
 * 其余初始化序列与 badvpn main() 保持一致。
 */

#include "tun2socks/tun2socks.c"

/* 返回值约定：0 成功；负值为错误码（Kotlin 侧 Tun2Socks 镜像定义） */
#define T2S_OK                    0
#define T2S_ERR_ALREADY_RUNNING  -1
#define T2S_ERR_INVALID_ARG      -2
#define T2S_ERR_THREAD_CREATE    -3
#define T2S_ERR_START_TIMEOUT    -4
#define T2S_ERR_INIT_BASE        -10 /* BNetwork_GlobalInit 失败 */
#define T2S_ERR_INIT_REACTOR     -11 /* BReactor_Init 失败 */
#define T2S_ERR_INIT_SIGNAL      -12 /* BSignal_Init 失败 */
#define T2S_ERR_INIT_TUN         -13 /* BTap_Init2 失败 */
#define T2S_ERR_INIT_ARGS        -14 /* process_arguments 失败（地址不合法） */
#define T2S_ERR_INIT_DEVICE      -15 /* 设备读通道初始化失败 */
#define T2S_ERR_INIT_UDPGW       -16 /* SocksUdpGwClient_Init 失败 */
#define T2S_ERR_INIT_BUF         -17 /* 设备写缓冲分配失败 */

#define T2S_STR_LEN 128
#define T2S_START_TIMEOUT_SEC 10

static char g_netif_ip[T2S_STR_LEN];
static char g_netif_mask[T2S_STR_LEN];
static char g_socks_addr[T2S_STR_LEN];
static char g_udpgw_addr[T2S_STR_LEN];
static int g_udpgw_enabled;
static int g_tun_fd;
static int g_tun_mtu;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;
static pthread_t g_thread;
static int g_thread_started;
static int g_start_done;
static int g_start_error;

/* 初始化并运行事件循环；返回 0 或负值错误码（进入事件循环前通过条件变量上报就绪） */
static int t2s_init_and_run (void)
{
    open_standard_streams();

    options.help = 0;
    options.version = 0;
    options.logger = LOGGER_STDOUT;
    options.loglevel = 0; /* BLOG_ERROR：静默运行，仅报错输出 */
    for (int i = 0; i < BLOG_NUM_CHANNELS; i++) {
        options.loglevels[i] = -1;
    }
    options.tundev = NULL;
    options.netif_ipaddr = g_netif_ip;
    options.netif_netmask = g_netif_mask;
    options.netif_ip6addr = NULL;
    options.socks_server_addr = g_socks_addr;
    options.username = NULL;
    options.password = NULL;
    options.password_file = NULL;
    options.append_source_to_username = 0;
    options.udpgw_remote_server_addr = g_udpgw_enabled ? g_udpgw_addr : NULL;
    options.udpgw_max_connections = DEFAULT_UDPGW_MAX_CONNECTIONS;
    options.udpgw_connection_buffer_size = DEFAULT_UDPGW_CONNECTION_BUFFER_SIZE;
    options.udpgw_transparent_dns = g_udpgw_enabled;
    options.socks5_udp = 0;

    BLog_InitStdout();
    for (int i = 0; i < BLOG_NUM_CHANNELS; i++) {
        if (options.loglevels[i] >= 0) {
            BLog_SetChannelLoglevel(i, options.loglevels[i]);
        }
        else if (options.loglevel >= 0) {
            BLog_SetChannelLoglevel(i, options.loglevel);
        }
    }

    if (!BNetwork_GlobalInit()) {
        BLog_Free();
        return T2S_ERR_INIT_BASE;
    }

    BTime_Init();

    if (!BReactor_Init(&ss)) {
        BLog_Free();
        return T2S_ERR_INIT_REACTOR;
    }

    quitting = 0;

    if (!BSignal_Init(&ss, signal_handler, NULL)) {
        BReactor_Free(&ss);
        BLog_Free();
        return T2S_ERR_INIT_SIGNAL;
    }

    /* 与 badvpn main() 的差异点：fd 方式接入 VpnService 的 tun */
    struct BTap_init_data init_data;
    init_data.dev_type = BTAP_DEV_TUN;
    init_data.init_type = BTAP_INIT_FD;
    init_data.init.fd.fd = g_tun_fd;
    init_data.init.fd.mtu = g_tun_mtu;

    if (!BTap_Init2(&device, &ss, init_data, device_error_handler, NULL)) {
        BSignal_Finish();
        BReactor_Free(&ss);
        BLog_Free();
        return T2S_ERR_INIT_TUN;
    }

    if (!process_arguments()) {
        BTap_Free(&device);
        BSignal_Finish();
        BReactor_Free(&ss);
        BLog_Free();
        return T2S_ERR_INIT_ARGS;
    }

    PacketPassInterface_Init(&device_read_interface, BTap_GetMTU(&device), device_read_handler_send, NULL, BReactor_PendingGroup(&ss));
    if (!SinglePacketBuffer_Init(&device_read_buffer, BTap_GetOutput(&device), &device_read_interface, BReactor_PendingGroup(&ss))) {
        PacketPassInterface_Free(&device_read_interface);
        BTap_Free(&device);
        BSignal_Finish();
        BReactor_Free(&ss);
        BLog_Free();
        return T2S_ERR_INIT_DEVICE;
    }

    /* 仅 IPv4 统计 UDP MTU（netif_ip6addr 恒为空，与 main 的算法保持一致） */
    udp_mtu = BTap_GetMTU(&device) - (int)(sizeof(struct ipv4_header) + sizeof(struct udp_header));
    if (udp_mtu < 0) {
        udp_mtu = 0;
    }

    if (options.udpgw_remote_server_addr) {
        udp_mode = UdpModeUdpgw;

        int udpgw_mtu = udpgw_compute_mtu(udp_mtu);
        if (udpgw_mtu < 0 || udpgw_mtu > PACKETPROTO_MAXPAYLOAD) {
            SinglePacketBuffer_Free(&device_read_buffer);
            PacketPassInterface_Free(&device_read_interface);
            BTap_Free(&device);
            BSignal_Finish();
            BReactor_Free(&ss);
            BLog_Free();
            return T2S_ERR_INIT_UDPGW;
        }

        if (!SocksUdpGwClient_Init(&udpgw_client, udp_mtu, DEFAULT_UDPGW_MAX_CONNECTIONS,
            options.udpgw_connection_buffer_size, UDPGW_KEEPALIVE_TIME, socks_server_addr,
            socks_auth_info, socks_num_auth_info, udpgw_remote_server_addr,
            UDPGW_RECONNECT_TIME, &ss, NULL, udp_send_packet_to_device))
        {
            SinglePacketBuffer_Free(&device_read_buffer);
            PacketPassInterface_Free(&device_read_interface);
            BTap_Free(&device);
            BSignal_Finish();
            BReactor_Free(&ss);
            BLog_Free();
            return T2S_ERR_INIT_UDPGW;
        }
    } else {
        udp_mode = UdpModeNone;
    }

    BPending_Init(&lwip_init_job, BReactor_PendingGroup(&ss), lwip_init_job_hadler, NULL);
    BPending_Set(&lwip_init_job);

    if (!(device_write_buf = (uint8_t *)BAlloc(BTap_GetMTU(&device)))) {
        if (udp_mode == UdpModeUdpgw) {
            SocksUdpGwClient_Free(&udpgw_client);
        }
        BPending_Free(&lwip_init_job);
        SinglePacketBuffer_Free(&device_read_buffer);
        PacketPassInterface_Free(&device_read_interface);
        BTap_Free(&device);
        BSignal_Finish();
        BReactor_Free(&ss);
        BLog_Free();
        return T2S_ERR_INIT_BUF;
    }

    BTimer_Init(&tcp_timer, TCP_TMR_INTERVAL, tcp_timer_handler, NULL);
    BReactor_SetTimer(&ss, &tcp_timer);
    tcp_timer_mod4 = 0;

    have_netif = 0;
    listener = NULL;
    listener_ip6 = NULL;
    LinkedList1_Init(&tcp_clients);
    num_clients = 0;

    /* 初始化全部完成，通知 JNI 调用方启动成功 */
    pthread_mutex_lock(&g_lock);
    g_start_error = T2S_OK;
    g_start_done = 1;
    pthread_cond_broadcast(&g_cond);
    pthread_mutex_unlock(&g_lock);

    BReactor_Exec(&ss);

    /* 事件循环退出后的清理序列，与 badvpn main() 一致 */
    LinkedList1Node *node;
    while ((node = LinkedList1_GetFirst(&tcp_clients)) != NULL) {
        struct tcp_client *client = UPPER_OBJECT(node, struct tcp_client, list_node);
        client_murder(client);
    }

    if (listener_ip6) {
        tcp_close(listener_ip6);
    }
    if (listener) {
        tcp_close(listener);
    }

    if (have_netif) {
        netif_remove(&the_netif);
    }

    BReactor_RemoveTimer(&ss, &tcp_timer);
    BFree(device_write_buf);
    BPending_Free(&lwip_init_job);
    if (udp_mode == UdpModeUdpgw) {
        SocksUdpGwClient_Free(&udpgw_client);
    }
    SinglePacketBuffer_Free(&device_read_buffer);
    PacketPassInterface_Free(&device_read_interface);
    BTap_Free(&device);
    BSignal_Finish();
    BReactor_Free(&ss);
    BLog_Free();

    return T2S_OK;
}

static void *t2s_thread_main (void *unused)
{
    int err = t2s_init_and_run();

    pthread_mutex_lock(&g_lock);
    if (!g_start_done) {
        /* 初始化失败路径：上报错误 */
        g_start_error = err;
        g_start_done = 1;
        pthread_cond_broadcast(&g_cond);
    }
    pthread_mutex_unlock(&g_lock);

    return NULL;
}

static int copy_jstring (JNIEnv *env, jstring src, char *dst, int dst_size)
{
    const char *utf = (*env)->GetStringUTFChars(env, src, NULL);
    if (!utf) {
        return -1;
    }
    strncpy(dst, utf, dst_size - 1);
    dst[dst_size - 1] = '\0';
    (*env)->ReleaseStringUTFChars(env, src, utf);
    return 0;
}

JNIEXPORT jint JNICALL Java_com_proxyscan_proxy_config_scan_vpn_Tun2Socks_run (
    JNIEnv *env, jclass clazz,
    jint tun_fd, jint mtu,
    jstring netif_ip, jstring netif_mask,
    jstring socks_addr, jstring udpgw_addr)
{
    (void)clazz;

    if (tun_fd < 0 || mtu <= 0 || netif_ip == NULL || netif_mask == NULL || socks_addr == NULL) {
        return T2S_ERR_INVALID_ARG;
    }

    pthread_mutex_lock(&g_lock);
    if (g_thread_started) {
        pthread_mutex_unlock(&g_lock);
        return T2S_ERR_ALREADY_RUNNING;
    }
    pthread_mutex_unlock(&g_lock);

    if (copy_jstring(env, netif_ip, g_netif_ip, sizeof(g_netif_ip)) < 0 ||
        copy_jstring(env, netif_mask, g_netif_mask, sizeof(g_netif_mask)) < 0 ||
        copy_jstring(env, socks_addr, g_socks_addr, sizeof(g_socks_addr)) < 0)
    {
        return T2S_ERR_INVALID_ARG;
    }

    if (udpgw_addr != NULL) {
        if (copy_jstring(env, udpgw_addr, g_udpgw_addr, sizeof(g_udpgw_addr)) < 0) {
            return T2S_ERR_INVALID_ARG;
        }
        g_udpgw_enabled = 1;
    } else {
        g_udpgw_enabled = 0;
    }

    g_tun_fd = tun_fd;
    g_tun_mtu = mtu;

    pthread_mutex_lock(&g_lock);
    g_start_done = 0;
    g_start_error = T2S_OK;

    int rc = pthread_create(&g_thread, NULL, t2s_thread_main, NULL);
    if (rc != 0) {
        pthread_mutex_unlock(&g_lock);
        return T2S_ERR_THREAD_CREATE;
    }
    g_thread_started = 1;

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += T2S_START_TIMEOUT_SEC;
    while (!g_start_done) {
        rc = pthread_cond_timedwait(&g_cond, &g_lock, &ts);
        if (rc == ETIMEDOUT) {
            break;
        }
    }

    if (!g_start_done) {
        /* 启动超时：线程仍在初始化中，交由 stop() 终止，避免 join 死等 */
        pthread_mutex_unlock(&g_lock);
        return T2S_ERR_START_TIMEOUT;
    }

    int err = g_start_error;
    pthread_t thread = g_thread;
    if (err != T2S_OK) {
        g_thread_started = 0;
    }
    pthread_mutex_unlock(&g_lock);

    if (err != T2S_OK) {
        pthread_join(thread, NULL);
    }

    return err;
}

JNIEXPORT jint JNICALL Java_com_proxyscan_proxy_config_scan_vpn_Tun2Socks_stop (
    JNIEnv *env, jclass clazz)
{
    (void)env;
    (void)clazz;

    pthread_mutex_lock(&g_lock);
    if (!g_thread_started) {
        pthread_mutex_unlock(&g_lock);
        return T2S_OK;
    }
    pthread_t thread = g_thread;
    g_thread_started = 0;
    pthread_mutex_unlock(&g_lock);

    /* terminate()：quitting=1 + BReactor_Quit；TCP 定时器保证 ≤250ms 内醒来退出。
     * 设备错误等场景可能已触发 terminate()（quitting==1），重复调用会踩 ASSERT，跳过 */
    if (!quitting) {
        terminate();
    }
    pthread_join(thread, NULL);

    return T2S_OK;
}
