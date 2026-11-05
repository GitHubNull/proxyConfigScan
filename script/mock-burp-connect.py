#!/usr/bin/env python3
"""M2 链路验证用 Burp 替身：监听 CONNECT，记录目标，回复 200 后双向转发。

仅标准库，无需 venv。真机 VPN 打通验证专用——生产环境请用 Burp
（listener 需绑局域网 IP，见 doc/build-run.md）。

用法: python3 script/mock-burp-connect.py [port] [logfile]
"""
import socket
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8081
LOG = sys.argv[2] if len(sys.argv) > 2 else "tmp/connect-log.txt"


def log(msg: str) -> None:
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def read_header(conn: socket.socket) -> bytes:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(1)
        if not chunk:
            raise ConnectionError("客户端在 CONNECT 完成前断开")
        data += chunk
        if len(data) > 65536:
            raise ConnectionError("CONNECT 请求头过大")
    return data


def relay(src: socket.socket, dst: socket.socket) -> None:
    try:
        while True:
            data = src.recv(16384)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(conn: socket.socket, addr) -> None:
    try:
        header = read_header(conn)
        line = header.split(b"\r\n", 1)[0].decode("iso-8859-1", "replace")
        parts = line.split()
        if len(parts) < 2 or parts[0].upper() != "CONNECT":
            log(f"[拒绝] 非 CONNECT 请求: {line!r} from {addr}")
            conn.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            return
        host, _, port = parts[1].rpartition(":")
        log(f"[CONNECT] {host}:{port} from {addr}")
        try:
            upstream = socket.create_connection((host, int(port)), timeout=10)
        except OSError as e:
            log(f"[失败] {host}:{port} 连不上: {e}")
            conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return
        conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        log(f"[隧道] {host}:{port} 建立")
        t = threading.Thread(target=relay, args=(conn, upstream), daemon=True)
        t.start()
        relay(upstream, conn)
        log(f"[关闭] {host}:{port}")
    except (ConnectionError, OSError) as e:
        log(f"[异常] {addr}: {e}")
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main() -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT))
    srv.listen(64)
    log(f"[*] mock-burp CONNECT 代理监听 0.0.0.0:{PORT}，日志 {LOG}")
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    main()
