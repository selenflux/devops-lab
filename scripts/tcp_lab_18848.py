#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# author: selenflux
"""
TCP 状态批量模拟脚本
默认端口：18848
默认地址：127.0.0.1

可模拟：
- LISTEN
- ESTABLISHED / ESTAB
- CLOSE-WAIT
- FIN-WAIT-2
- TIME-WAIT
- 可选 SYN-SENT

查看命令：
ss -tan '( sport = :18848 or dport = :18848 )'
"""

import argparse
import errno
import signal
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

# resource 是 Unix 专属模块，Windows 下优雅降级
try:
    import resource
    HAS_RESOURCE = True
except ImportError:
    HAS_RESOURCE = False

stop_event = threading.Event()
lock = threading.Lock()
cleaned = False

buckets = {
    "listen": [],
    "established_client": [],
    "established_server": [],
    "closewait_server": [],
    "finwait2_client": [],
    "synsent_client": [],
    "other": [],
}

MAX_PRINT_ERRORS = 5  # 每类错误最多打印的条数，防止刷屏


def keep(sock, name):
    sock.settimeout(None)  # 被持有的 socket 必须恢复阻塞态，避免超时误杀
    with lock:
        buckets.setdefault(name, []).append(sock)


def close_quietly(sock):
    try:
        sock.close()
    except Exception:
        pass


def cleanup():
    global cleaned
    stop_event.set()
    with lock:
        if cleaned:
            return
        cleaned = True
        for name, socks in buckets.items():
            for s in socks:
                close_quietly(s)
            socks.clear()


def on_signal(signum, frame):
    print("\n[+] 收到退出信号，正在关闭 socket ...")
    cleanup()
    sys.exit(0)


def raise_nofile_limit(wanted):
    if not HAS_RESOURCE:
        print("[!] 当前平台无 resource 模块（Windows？），跳过 RLIMIT_NOFILE 调整")
        return
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        if soft < wanted:
            new_soft = min(wanted, hard)
            resource.setrlimit(resource.RLIMIT_NOFILE, (new_soft, hard))
            print(f"[+] RLIMIT_NOFILE: {soft} -> {new_soft}, hard={hard}")
            if new_soft < wanted:
                print(f"[!] 当前 hard limit 不足，建议先执行：ulimit -n {wanted}")
        else:
            print(f"[+] RLIMIT_NOFILE 当前为 {soft}")
    except Exception as e:
        print(f"[!] 调整文件描述符限制失败：{e}")


def handle_conn(conn, addr):
    """
    客户端发 1 个字节表示模式：
    E = ESTABLISHED，双方保持不关
    C = CLOSE-WAIT，客户端 shutdown 写方向，服务端收到 FIN 后不 close
    T = TIME-WAIT，服务端主动 close，让服务端口进入 TIME-WAIT
    其他 = 关闭连接，不再持有
    """
    try:
        conn.settimeout(10)
        try:
            mode = conn.recv(1)
        except socket.timeout:
            close_quietly(conn)
            return

        if mode == b"E":
            keep(conn, "established_server")

        elif mode == b"C":
            # 持续读到 EOF（对端 FIN），然后不 close，服务端停留在 CLOSE-WAIT
            try:
                while True:
                    data = conn.recv(4096)
                    if data == b"":
                        break
                keep(conn, "closewait_server")
            except socket.timeout:
                # 本机回环下对端 FIN 很快到达；超时说明对端异常，放弃该连接
                close_quietly(conn)

        elif mode == b"T":
            # 服务端主动关闭，服务端进入 TIME-WAIT
            close_quietly(conn)

        else:
            # 未知模式：直接关闭，不持有
            close_quietly(conn)

    except Exception:
        close_quietly(conn)


def start_server(bind_ip, port, backlog, workers):
    """
    服务端 socket 在主线程完成 bind/listen，
    端口占用等错误能立刻报错退出，而不是线程里静默失败。
    """
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind((bind_ip, port))
    except OSError as e:
        print(f"[!] bind {bind_ip}:{port} 失败：{e}")
        sys.exit(1)
    srv.listen(backlog)
    srv.settimeout(1)
    keep(srv, "listen")

    print(f"[+] LISTEN: {bind_ip}:{port}, backlog={backlog} "
          f"(实际受 net.core.somaxconn 限制)")

    executor = ThreadPoolExecutor(max_workers=workers)

    def accept_loop():
        while not stop_event.is_set():
            try:
                conn, addr = srv.accept()
                executor.submit(handle_conn, conn, addr)
            except socket.timeout:
                continue
            except OSError:
                if stop_event.is_set():
                    break
                # listen socket 已被 cleanup 关闭等场景，直接退出循环
                break

    t = threading.Thread(target=accept_loop, daemon=True)
    t.start()
    return t


def create_established(host, port, count):
    ok = 0
    fail = 0

    for i in range(count):
        s = None
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(10)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.connect((host, port))
            s.sendall(b"E")
            keep(s, "established_client")
            ok += 1
        except Exception as e:
            fail += 1
            if s:
                close_quietly(s)
            if fail <= MAX_PRINT_ERRORS:
                print(f"[!] ESTABLISHED 创建失败（第 {fail} 次）：{e}")

    print(f"[+] ESTABLISHED client 创建完成：ok={ok}, fail={fail}")


def create_close_wait_and_finwait2(host, port, count):
    """
    客户端：connect -> send C -> shutdown(SHUT_WR) -> 保持不关 -> FIN‑WAIT‑2
    服务端：收到 FIN 后不 close -> CLOSE‑WAIT
    """
    ok = 0
    fail = 0

    for i in range(count):
        s = None
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(10)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.connect((host, port))
            s.sendall(b"C")
            s.shutdown(socket.SHUT_WR)
            keep(s, "finwait2_client")
            ok += 1
        except Exception as e:
            fail += 1
            if s:
                close_quietly(s)
            if fail <= MAX_PRINT_ERRORS:
                print(f"[!] CLOSE‑WAIT / FIN‑WAIT‑2 创建失败（第 {fail} 次）：{e}")

    print(f"[+] CLOSE‑WAIT / FIN‑WAIT‑2 创建完成：ok={ok}, fail={fail}")


def one_timewait_conn(host, port):
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(10)  # 防止服务端 FIN 迟迟不到时线程永久挂死
        s.connect((host, port))
        s.sendall(b"T")

        # 等待服务端主动关闭（读到 EOF）
        while s.recv(4096):
            pass

        close_quietly(s)
        return True
    except Exception:
        if s:
            close_quietly(s)
        return False


def create_timewait(host, port, count, workers):
    ok = 0
    fail = 0

    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(one_timewait_conn, host, port) for _ in range(count)]

        for f in as_completed(futures):
            if f.result():
                ok += 1
            else:
                fail += 1

    print(f"[+] TIME‑WAIT 创建完成：ok={ok}, fail={fail}")


def create_syn_sent(target_ip, port, count):
    """
    SYN‑SENT 需要目标不回应 SYN，默认不开启。
    只在自己的实验环境使用，不要对公网或生产目标使用。
    """
    ok = 0
    fail = 0

    for i in range(count):
        s = None
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setblocking(False)
            ret = s.connect_ex((target_ip, port))

            if ret in (errno.EINPROGRESS, errno.EWOULDBLOCK, errno.EALREADY):
                keep(s, "synsent_client")
                ok += 1
            elif ret == 0:
                # 目标居然连上了，就不是 SYN‑SENT，直接关闭
                close_quietly(s)
                fail += 1
            else:
                fail += 1
                close_quietly(s)

        except Exception:
            fail += 1
            if s:
                close_quietly(s)

    print(f"[+] SYN‑SENT 尝试创建完成：ok={ok}, fail={fail}, target={target_ip}:{port}")


def print_local_bucket_stats():
    with lock:
        print("\n[Python 持有 socket 数]")
        for name, socks in buckets.items():
            print(f"  {name:<22} {len(socks)}")


def print_ss_stats(port):
    print("\n[ss 统计]")
    cmd = (
        f"ss -tan '( sport = :{port} or dport = :{port} )' "
        "| awk 'NR>1 {a[$1]++} END {for (k in a) print k, a[k]}'"
    )

    try:
        subprocess.run(cmd, shell=True, check=False)
    except Exception as e:
        print(f"[!] 执行 ss 失败：{e}（ss 为 Linux 命令，Windows 下请跳过）")


def main():
    parser = argparse.ArgumentParser(
        description="Batch create TCP states on a local lab port"
    )

    parser.add_argument("--bind", default="127.0.0.1", help="服务端监听地址，默认 127.0.0.1")
    parser.add_argument("--host", default="127.0.0.1", help="客户端连接地址，默认 127.0.0.1")
    parser.add_argument("--port", type=int, default=18848,
                        help="端口，默认 18848（避开 Nacos 的 8848，防止实验撞上真实服务）")

    parser.add_argument("--established", type=int, default=100, help="创建 ESTABLISHED 数量，默认 100")
    parser.add_argument("--closewait", type=int, default=100, help="创建 CLOSE‑WAIT / FIN‑WAIT‑2 数量，默认 100")
    parser.add_argument("--timewait", type=int, default=500, help="创建 TIME‑WAIT 数量，默认 500")

    parser.add_argument("--synsent", type=int, default=0, help="创建 SYN‑SENT 数量，默认 0")
    parser.add_argument("--syn-target", default="10.255.255.1", help="SYN‑SENT 目标 IP，默认 10.255.255.1")

    parser.add_argument("--backlog", type=int, default=1024,
                        help="listen backlog，默认 1024（实际受 net.core.somaxconn 限制）")
    parser.add_argument("--accept-workers", type=int, default=100, help="服务端处理线程数，默认 100")
    parser.add_argument("--timewait-workers", type=int, default=100, help="TIME‑WAIT 并发创建线程数，默认 100")

    parser.add_argument("--hold", type=int, default=300, help="保持时间（秒），0 表示一直保持，默认 300")
    parser.add_argument("--interval", type=int, default=5, help="打印 ss 统计间隔（秒），默认 5")

    args = parser.parse_args()

    if args.interval <= 0:
        args.interval = 5

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    # fd 预算：双端持有的连接 + SYN‑SENT + TIME‑WAIT 并发瞬态 + 余量
    fd_need = (
        2 * (args.established + args.closewait)
        + args.synsent
        + args.timewait_workers
        + 1024
    )
    raise_nofile_limit(fd_need)

    start_server(args.bind, args.port, args.backlog, args.accept_workers)
    time.sleep(0.5)

    if args.established > 0:
        create_established(args.host, args.port, args.established)

    if args.closewait > 0:
        create_close_wait_and_finwait2(args.host, args.port, args.closewait)

    # 等待 CLOSE‑WAIT / FIN‑WAIT‑2 状态稳定
    time.sleep(1)

    if args.timewait > 0:
        create_timewait(args.host, args.port, args.timewait, args.timewait_workers)

    if args.synsent > 0:
        print("[!] SYN‑SENT 会连接一个不响应目标，请只在自己的实验环境使用。")
        create_syn_sent(args.syn_target, args.port, args.synsent)

    ss_filter = f"( sport = :{args.port} or dport = :{args.port} )"
    print("\n[+] 创建动作完成。")
    print(f"[+] 查看命令：ss -tan '{ss_filter}'")
    print(f"[+] 统计命令：ss -tan '{ss_filter}' | awk 'NR>1 {{a[$1]++}} END {{for (k in a) print k, a[k]}}'")
    print("[+] 按 Ctrl+C 退出并关闭持有的 socket。")

    start = time.time()

    while not stop_event.is_set():
        print_local_bucket_stats()
        print_ss_stats(args.port)

        if args.hold > 0 and time.time() - start >= args.hold:
            break

        time.sleep(args.interval)

    cleanup()
    print("[+] 已退出。")


if __name__ == "__main__":
    main()
