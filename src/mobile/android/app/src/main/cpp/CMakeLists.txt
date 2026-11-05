cmake_minimum_required(VERSION 3.10)
project(tun2socks C)

# badvpn 源码树位置：由 script/build-tun2socks.sh 通过 -DBADVPN_SRC 传入
if (NOT DEFINED BADVPN_SRC OR BADVPN_SRC STREQUAL "")
    if (NOT "$ENV{BADVPN_SRC}" STREQUAL "")
        set(BADVPN_SRC "$ENV{BADVPN_SRC}")
    endif ()
endif ()
if (NOT EXISTS "${BADVPN_SRC}/tun2socks/tun2socks.c")
    message(FATAL_ERROR "BADVPN_SRC 未指向 badvpn 源码树（缺 tun2socks/tun2socks.c），请先运行 script/build-tun2socks.sh 拉取源码")
endif ()

# flow/flowextra 组件全部源文件均为可移植实现，直接收集
file(GLOB FLOW_SOURCES "${BADVPN_SRC}/flow/*.c" "${BADVPN_SRC}/flowextra/*.c")

add_library(tun2socks SHARED
    tun2socks_jni.c
    ${FLOW_SOURCES}
    # tun2socks（其入口逻辑在 JNI 包装器中按需驱动，main 不参与链接调用）
    ${BADVPN_SRC}/tun2socks/SocksUdpGwClient.c
    # base
    ${BADVPN_SRC}/base/DebugObject.c
    ${BADVPN_SRC}/base/BLog.c
    ${BADVPN_SRC}/base/BPending.c
    # system（Android 走 Linux/epoll/signalfd 路径；BProcess/BInputProcess 为 NCD 专用，不编入）
    ${BADVPN_SRC}/system/BTime.c
    ${BADVPN_SRC}/system/BSignal.c
    ${BADVPN_SRC}/system/BNetwork.c
    ${BADVPN_SRC}/system/BConnection_common.c
    ${BADVPN_SRC}/system/BDatagram_common.c
    ${BADVPN_SRC}/system/BUnixSignal.c
    ${BADVPN_SRC}/system/BConnection_unix.c
    ${BADVPN_SRC}/system/BDatagram_unix.c
    ${BADVPN_SRC}/system/BThreadSignal.c
    ${BADVPN_SRC}/system/BLockReactor.c
    ${BADVPN_SRC}/system/BReactor_badvpn.c
    # tuntap（BTap_Init2 的 BTAP_INIT_FD 路径接收 VpnService 的 tun fd）
    ${BADVPN_SRC}/tuntap/BTap.c
    # socks5 客户端 / udpgw 客户端（SocksUdpClient 虽不使用 socks5_udp 模式，但 tun2socks.c 有符号引用，必须编入）
    ${BADVPN_SRC}/socksclient/BSocksClient.c
    ${BADVPN_SRC}/udpgw_client/UdpGwClient.c
    ${BADVPN_SRC}/socks_udp_client/SocksUdpClient.c
    # lwip（与 badvpn 官方组件清单一致：core + ipv4 + ipv6 + custom）
    ${BADVPN_SRC}/lwip/custom/sys.c
    ${BADVPN_SRC}/lwip/src/core/udp.c
    ${BADVPN_SRC}/lwip/src/core/memp.c
    ${BADVPN_SRC}/lwip/src/core/init.c
    ${BADVPN_SRC}/lwip/src/core/pbuf.c
    ${BADVPN_SRC}/lwip/src/core/tcp.c
    ${BADVPN_SRC}/lwip/src/core/tcp_out.c
    ${BADVPN_SRC}/lwip/src/core/sys.c
    ${BADVPN_SRC}/lwip/src/core/netif.c
    ${BADVPN_SRC}/lwip/src/core/def.c
    ${BADVPN_SRC}/lwip/src/core/mem.c
    ${BADVPN_SRC}/lwip/src/core/tcp_in.c
    ${BADVPN_SRC}/lwip/src/core/stats.c
    ${BADVPN_SRC}/lwip/src/core/ip.c
    ${BADVPN_SRC}/lwip/src/core/timeouts.c
    ${BADVPN_SRC}/lwip/src/core/inet_chksum.c
    ${BADVPN_SRC}/lwip/src/core/ipv4/icmp.c
    ${BADVPN_SRC}/lwip/src/core/ipv4/ip4.c
    ${BADVPN_SRC}/lwip/src/core/ipv4/ip4_addr.c
    ${BADVPN_SRC}/lwip/src/core/ipv4/ip4_frag.c
    ${BADVPN_SRC}/lwip/src/core/ipv6/ip6.c
    ${BADVPN_SRC}/lwip/src/core/ipv6/nd6.c
    ${BADVPN_SRC}/lwip/src/core/ipv6/icmp6.c
    ${BADVPN_SRC}/lwip/src/core/ipv6/ip6_addr.c
    ${BADVPN_SRC}/lwip/src/core/ipv6/ip6_frag.c
)

target_compile_definitions(tun2socks PRIVATE
    BADVPN_LINUX
    BADVPN_USE_EPOLL
    BADVPN_USE_SIGNALFD
    BADVPN_BREACTOR_BADVPN
    BADVPN_LITTLE_ENDIAN
    BADVPN_THREAD_SAFE=1
    BADVPN_THREADWORK_USE_PTHREAD
)

target_include_directories(tun2socks PRIVATE
    ${BADVPN_SRC}
    ${BADVPN_SRC}/lwip/custom
    ${BADVPN_SRC}/lwip/src/include
    ${BADVPN_SRC}/lwip/src/include/ipv4
    ${BADVPN_SRC}/lwip/src/include/ipv6
)

# NDK 高版本 clang 将隐式函数声明视为错误，badvpn/lwip 老代码需要放宽
target_compile_options(tun2socks PRIVATE -O2 -fvisibility=hidden -Wno-implicit-function-declaration)

find_library(LIB_LOG log)
find_library(LIB_ANDROID android)
target_link_libraries(tun2socks PRIVATE ${LIB_LOG} ${LIB_ANDROID})
