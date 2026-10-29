#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HomeNet Portal Backend (Homepage-Style Architecture)
Zero-dependency, pure Python 3 standard library.
Coordinates: RouterOS REST, MosDNS, sing-box Clash-API, daed, Keepalived & Host Stats.
"""

import os
import re
import ssl
import time
import json
import base64
import socket
import urllib.request
import urllib.error
import subprocess
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(BASE_DIR, "static")
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")
EXAMPLE_CONFIG = os.path.join(BASE_DIR, "config.example.json")

# Default settings
DEFAULT_CONFIG = {
    "port": 8888,
    "refresh_interval_sec": 3,
    "routeros": {
        "enabled": True,
        "host": "10.10.11.1",
        "port": 80,
        "use_ssl": False,
        "username": "admin",
        "password": "",
        "wan_interface": "ether1"
    },
    "mosdns": {
        "service_name": "mosdns",
        "port": 53,
        "log_file": "/etc/mosdns/mosdns.log"
    },
    "singbox": {
        "clash_api": "http://127.0.0.1:9090",
        "secret": ""
    },
    "daed": {
        "url": "http://127.0.0.1:2023"
    },
    "keepalived": {
        "vip": "10.10.11.10"
    },
    "pve": {
        "host": "10.10.11.2",
        "port": 8006
    }
}

def load_config():
    cfg = DEFAULT_CONFIG.copy()
    target_file = CONFIG_PATH if os.path.exists(CONFIG_PATH) else EXAMPLE_CONFIG
    if os.path.exists(target_file):
        try:
            with open(target_file, "r", encoding="utf-8") as f:
                user_cfg = json.load(f)
                for k, v in user_cfg.items():
                    if isinstance(v, dict) and k in cfg and isinstance(cfg[k], dict):
                        cfg[k].update(v)
                    else:
                        cfg[k] = v
        except Exception as e:
            print(f"[WARN] Failed to parse {target_file}: {e}")
    return cfg

CONFIG = load_config()

# Global state for traffic rate calculation
STATE = {
    "singbox_last_poll": 0,
    "singbox_last_down": 0,
    "singbox_last_up": 0,
    "singbox_down_bps": 0,
    "singbox_up_bps": 0,
    "ros_last_poll": 0,
    "ros_last_rx": 0,
    "ros_last_tx": 0,
    "ros_rx_bps": 0,
    "ros_tx_bps": 0,
    "public_ip_cache": {"ip": "检测中...", "country": "", "isp": "", "last_check": 0}
}

def format_bytes(n):
    if not isinstance(n, (int, float)) or n <= 0:
        return "0 B"
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if n < 1024.0:
            return f"{n:.1f} {unit}"
        n /= 1024.0
    return f"{n:.1f} PB"

def format_speed(bps):
    if not isinstance(bps, (int, float)) or bps <= 0:
        return "0 B/s"
    for unit in ["B/s", "KB/s", "MB/s", "GB/s"]:
        if bps < 1024.0:
            return f"{bps:.1f} {unit}"
        bps /= 1024.0
    return f"{bps:.1f} TB/s"

def check_tcp(host, port, timeout=0.8):
    start = time.time()
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            latency = round((time.time() - start) * 1000, 1)
            return {"online": True, "latency": latency, "text": f"{latency} ms"}
    except Exception:
        return {"online": False, "latency": None, "text": "连接超时"}

def check_icmp(host, timeout=1.0):
    try:
        res = subprocess.run(
            ["ping", "-c", "1", "-W", "1", host],
            capture_output=True,
            text=True,
            timeout=timeout
        )
        if res.returncode == 0:
            m = re.search(r"time=([\d\.]+)", res.stdout)
            lat = round(float(m.group(1)), 1) if m else 0.5
            return {"online": True, "latency": lat, "text": f"{lat} ms"}
    except Exception:
        pass
    return {"online": False, "latency": None, "text": "无响应"}

# --- RouterOS Metrics Collector ---
def get_routeros_metrics():
    ros_cfg = CONFIG.get("routeros", {})
    if not ros_cfg.get("enabled", True):
        return {"enabled": False}

    host = ros_cfg.get("host", "10.10.11.1")
    port = ros_cfg.get("port", 80)
    use_ssl = ros_cfg.get("use_ssl", False)
    username = ros_cfg.get("username", "admin")
    password = ros_cfg.get("password", "")
    wan_if = ros_cfg.get("wan_interface", "ether1")

    # Base connectivity via Winbox port 8291
    winbox_status = check_tcp(host, 8291, timeout=0.5)
    ping_status = check_icmp(host, timeout=0.8)

    base_result = {
        "host": host,
        "online": winbox_status["online"] or ping_status["online"],
        "winbox_port": 8291,
        "winbox_online": winbox_status["online"],
        "ping_ms": ping_status["latency"] or (winbox_status["latency"] if winbox_status["online"] else None),
        "rest_available": False,
        "cpu_load": None,
        "free_memory_mb": None,
        "total_memory_mb": None,
        "memory_pct": None,
        "uptime": None,
        "version": None,
        "board_name": None,
        "wan_rx_bps": 0,
        "wan_tx_bps": 0,
        "wan_rx_speed": "0 B/s",
        "wan_tx_speed": "0 B/s",
        "dhcp_leases": None,
        "msg": "Winbox 连通"
    }

    # Attempt REST query
    scheme = "https" if use_ssl else "http"
    base_url = f"{scheme}://{host}:{port}/rest"

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    def rest_get(path):
        url = f"{base_url}{path}"
        req = urllib.request.Request(url)
        auth = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
        req.add_header("Authorization", f"Basic {auth}")
        req.add_header("User-Agent", "HomeNet-Portal/2.0")
        with urllib.request.urlopen(req, timeout=1.5, context=ctx) as resp:
            if resp.status == 200:
                return json.loads(resp.read().decode("utf-8"))
        return None

    try:
        # 1. System Resource
        res = rest_get("/system/resource")
        if res:
            base_result["rest_available"] = True
            base_result["cpu_load"] = int(res.get("cpu-load", 0))
            free_mem = int(res.get("free-memory", 0))
            tot_mem = int(res.get("total-memory", 0))
            base_result["free_memory_mb"] = round(free_mem / 1024 / 1024)
            base_result["total_memory_mb"] = round(tot_mem / 1024 / 1024)
            if tot_mem > 0:
                base_result["memory_pct"] = round(((tot_mem - free_mem) / tot_mem) * 100, 1)
            base_result["uptime"] = res.get("uptime", "").replace("d", "天 ").replace("h", "时 ").replace("m", "分 ").replace("s", "秒")
            base_result["version"] = res.get("version", "")
            base_result["board_name"] = res.get("board-name", "RouterOS")

        # 2. Interface Traffic
        if base_result["rest_available"]:
            try:
                ifaces = rest_get("/interface")
                if isinstance(ifaces, list):
                    target_iface = None
                    for item in ifaces:
                        if item.get("name") == wan_if or item.get("comment", "").lower().find("wan") >= 0:
                            target_iface = item
                            break
                    if not target_iface and len(ifaces) > 0:
                        target_iface = ifaces[0]

                    if target_iface:
                        rx = int(target_iface.get("rx-byte", 0))
                        tx = int(target_iface.get("tx-byte", 0))
                        now = time.time()
                        last_t = STATE["ros_last_poll"]
                        if last_t > 0 and now > last_t:
                            dt = now - last_t
                            if rx >= STATE["ros_last_rx"]:
                                STATE["ros_rx_bps"] = (rx - STATE["ros_last_rx"]) / dt
                            if tx >= STATE["ros_last_tx"]:
                                STATE["ros_tx_bps"] = (tx - STATE["ros_last_tx"]) / dt
                        STATE["ros_last_poll"] = now
                        STATE["ros_last_rx"] = rx
                        STATE["ros_last_tx"] = tx

                        base_result["wan_rx_bps"] = STATE["ros_rx_bps"]
                        base_result["wan_tx_bps"] = STATE["ros_tx_bps"]
                        base_result["wan_rx_speed"] = format_speed(STATE["ros_rx_bps"])
                        base_result["wan_tx_speed"] = format_speed(STATE["ros_tx_bps"])
            except Exception:
                pass

        # 3. DHCP leases count
        if base_result["rest_available"]:
            try:
                leases = rest_get("/ip/dhcp-server/lease")
                if isinstance(leases, list):
                    active_leases = [l for l in leases if l.get("status") in ("bound", None)]
                    base_result["dhcp_leases"] = len(active_leases)
            except Exception:
                pass

    except urllib.error.HTTPError as e:
        base_result["msg"] = f"REST 认证失败 (HTTP {e.code})"
    except Exception as e:
        base_result["msg"] = "REST 未就绪 (需在 ROS 开启 www 端口 80)"

    return base_result

# --- MosDNS Metrics & Log Health Collector ---
def get_mosdns_metrics():
    mos_cfg = CONFIG.get("mosdns", {})
    service_name = mos_cfg.get("service_name", "mosdns")
    port = mos_cfg.get("port", 53)
    log_file = mos_cfg.get("log_file", "/etc/mosdns/mosdns.log")

    # 1. Systemd Service check
    service_active = False
    try:
        res = subprocess.run(["systemctl", "is-active", service_name], capture_output=True, text=True, timeout=1.0)
        service_active = (res.stdout.strip() == "active")
    except Exception:
        pass

    # 2. Port 53 check (UDP socket test)
    port_online = False
    dns_latency_ms = None
    try:
        # Simple UDP probe on 127.0.0.1:53 with a lightweight DNS header query
        start = time.time()
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.5)
        # Standard DNS query for localhost / test query (12 bytes header + qname)
        # ID: 0x1234, Flags: 0x0100 (standard query), QDCOUNT: 1
        query = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x03www\x05baidu\x03com\x00\x00\x01\x00\x01"
        s.sendto(query, ("127.0.0.1", int(port)))
        data, _ = s.recvfrom(512)
        s.close()
        if len(data) >= 12:
            port_online = True
            dns_latency_ms = round((time.time() - start) * 1000, 1)
    except Exception:
        # Fallback to TCP check
        tcp_check = check_tcp("127.0.0.1", port, timeout=0.4)
        port_online = tcp_check["online"]
        dns_latency_ms = tcp_check["latency"]

    # 3. Process CPU & Memory
    rss_mb = 0
    cpu_pct = 0.0
    pid = None
    try:
        res = subprocess.run(["pgrep", "-f", "mosdns start"], capture_output=True, text=True, timeout=1.0)
        pids = res.stdout.strip().split()
        if pids:
            pid = int(pids[0])
            with open(f"/proc/{pid}/statm", "r") as f:
                # 2nd number is resident pages
                rss_pages = int(f.readline().split()[1])
                rss_mb = round(rss_pages * os.sysconf("SC_PAGE_SIZE") / 1024 / 1024, 1)
    except Exception:
        pass

    # 4. Log Health Inspection (Audit tail of log file)
    errors_count = 0
    warns_count = 0
    latest_alert = None
    log_exists = os.path.exists(log_file)
    if log_exists:
        try:
            # Read last 64KB of log
            with open(log_file, "rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                seek_bytes = min(size, 65536)
                f.seek(-seek_bytes, os.SEEK_END)
                lines = f.read().decode("utf-8", errors="ignore").splitlines()

            for line in lines[-150:]:
                if "\tERROR\t" in line or "[ERROR]" in line or "level=error" in line:
                    errors_count += 1
                    latest_alert = line.strip()
                elif "\tWARN\t" in line or "[WARN]" in line or "level=warn" in line:
                    # Ignore normal shutdown/start termination signals
                    if "signal received" not in line and "closing plugin" not in line:
                        warns_count += 1
                        if not latest_alert:
                            latest_alert = line.strip()
        except Exception as e:
            pass

    return {
        "service_active": service_active,
        "port_online": port_online,
        "port": port,
        "pid": pid,
        "dns_latency_ms": dns_latency_ms,
        "memory_mb": rss_mb,
        "errors_count": errors_count,
        "warns_count": warns_count,
        "latest_alert": latest_alert,
        "log_exists": log_exists
    }

# --- Sing-box Metrics Collector ---
def get_singbox_metrics():
    sb_cfg = CONFIG.get("singbox", {})
    clash_api = sb_cfg.get("clash_api", "http://127.0.0.1:9090").rstrip("/")
    secret = sb_cfg.get("secret", "")

    headers = {}
    if secret:
        headers["Authorization"] = f"Bearer {secret}"

    def api_get(endpoint, timeout=1.0):
        req = urllib.request.Request(f"{clash_api}{endpoint}", headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status == 200:
                return json.loads(resp.read().decode("utf-8"))
        return None

    res = {
        "online": False,
        "current_node": "保底直连",
        "connections_count": 0,
        "download_bps": 0,
        "upload_bps": 0,
        "download_speed": "0 B/s",
        "upload_speed": "0 B/s",
        "download_total": "0 B",
        "upload_total": "0 B",
        "memory_mb": 0,
        "mode": "rule"
    }

    try:
        # Check connections and total traffic
        conn_data = api_get("/connections")
        if conn_data is not None:
            res["online"] = True
            conns = conn_data.get("connections", [])
            res["connections_count"] = len(conns)
            down_total = conn_data.get("downloadTotal", 0)
            up_total = conn_data.get("uploadTotal", 0)
            res["download_total"] = format_bytes(down_total)
            res["upload_total"] = format_bytes(up_total)
            res["memory_mb"] = round(conn_data.get("memory", 0) / 1024 / 1024, 1)

            # Compute real-time speed from delta
            now = time.time()
            last_t = STATE["singbox_last_poll"]
            if last_t > 0 and now > last_t:
                dt = now - last_t
                if down_total >= STATE["singbox_last_down"]:
                    STATE["singbox_down_bps"] = (down_total - STATE["singbox_last_down"]) / dt
                if up_total >= STATE["singbox_last_up"]:
                    STATE["singbox_up_bps"] = (up_total - STATE["singbox_last_up"]) / dt

            STATE["singbox_last_poll"] = now
            STATE["singbox_last_down"] = down_total
            STATE["singbox_last_up"] = up_total

            res["download_bps"] = STATE["singbox_down_bps"]
            res["upload_bps"] = STATE["singbox_up_bps"]
            res["download_speed"] = format_speed(STATE["singbox_down_bps"])
            res["upload_speed"] = format_speed(STATE["singbox_up_bps"])

        # Check proxies and active node
        proxy_data = api_get("/proxies")
        if proxy_data and "proxies" in proxy_data:
            proxies = proxy_data["proxies"]
            # Look for active outbound node
            for group_name in ["GLOBAL", "Sing-box连接", "主力线路", "节点选择", "PROXY"]:
                if group_name in proxies and "now" in proxies[group_name]:
                    res["current_node"] = proxies[group_name]["now"]
                    break
    except Exception:
        pass

    return res

# --- daed Collector ---
def get_daed_metrics():
    daed_cfg = CONFIG.get("daed", {})
    url = daed_cfg.get("url", "http://127.0.0.1:2023")
    tcp_res = check_tcp("127.0.0.1", 2023, timeout=0.5)
    return {
        "online": tcp_res["online"],
        "latency": tcp_res["latency"],
        "url": url,
        "text": tcp_res["text"]
    }

# --- Host System Metrics ---
def get_system_stats():
    uptime_str = "运行中"
    try:
        with open("/proc/uptime", "r") as f:
            sec = float(f.readline().split()[0])
            d, rem = divmod(int(sec), 86400)
            h, rem = divmod(rem, 3600)
            m, _ = divmod(rem, 60)
            uptime_str = f"{d}天 {h}时 {m}分" if d > 0 else f"{h}时 {m}分"
    except Exception:
        pass

    mem_used = "0 MB"
    mem_total = "0 MB"
    mem_pct = 0
    try:
        with open("/proc/meminfo", "r") as f:
            lines = f.readlines()
            info = {}
            for line in lines:
                parts = line.split(":")
                if len(parts) == 2:
                    info[parts[0].strip()] = int(parts[1].split()[0])
            total = info.get("MemTotal", 0)
            available = info.get("MemAvailable", 0)
            used = total - available
            mem_pct = round((used / total) * 100, 1) if total else 0
            mem_used = f"{round(used / 1024)} MB"
            mem_total = f"{round(total / 1024 / 1024, 1)} GB"
    except Exception:
        pass

    # Disk
    disk_pct = 0
    disk_used = "0 GB"
    disk_total = "0 GB"
    try:
        st = os.statvfs("/")
        total_b = st.f_blocks * st.f_frsize
        free_b = st.f_bavail * st.f_frsize
        used_b = total_b - free_b
        disk_pct = round((used_b / total_b) * 100, 1) if total_b else 0
        disk_used = f"{round(used_b / 1024 / 1024 / 1024, 1)} GB"
        disk_total = f"{round(total_b / 1024 / 1024 / 1024, 1)} GB"
    except Exception:
        pass

    load_avg = "0.00"
    try:
        load_avg = f"{os.getloadavg()[0]:.2f}"
    except Exception:
        pass

    return {
        "uptime": uptime_str,
        "mem_used": mem_used,
        "mem_total": mem_total,
        "mem_pct": mem_pct,
        "disk_used": disk_used,
        "disk_total": disk_total,
        "disk_pct": disk_pct,
        "load": load_avg
    }

# --- Keepalived & VIP Collector ---
def get_keepalived_metrics():
    vip = CONFIG.get("keepalived", {}).get("vip", "10.10.11.10")
    service_active = False
    try:
        res = subprocess.run(["systemctl", "is-active", "keepalived"], capture_output=True, text=True, timeout=0.8)
        service_active = (res.stdout.strip() == "active")
    except Exception:
        pass

    # Check if local interfaces hold the VIP
    is_master = False
    try:
        res = subprocess.run(["ip", "addr", "show"], capture_output=True, text=True, timeout=0.8)
        if vip in res.stdout:
            is_master = True
    except Exception:
        pass

    return {
        "service_active": service_active,
        "vip": vip,
        "is_master": is_master,
        "role_text": "MASTER (当前接管 VIP)" if is_master else "BACKUP (备机待命就绪)"
    }

# --- Public IP & Outbound Connectivity ---
def get_public_ip_info():
    now = time.time()
    cache = STATE["public_ip_cache"]
    # Refresh cache every 60 seconds
    if now - cache["last_check"] < 60 and cache["ip"] != "检测中...":
        return cache

    try:
        req = urllib.request.Request("https://api.ipify.org?format=json")
        with urllib.request.urlopen(req, timeout=1.8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            ip = data.get("ip", "")
            cache["ip"] = ip
            cache["last_check"] = now
    except Exception:
        pass

    return cache

# --- HTTP Request Handler ---
class PortalHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def do_GET(self):
        if self.path == "/api/status" or self.path == "/api/health":
            self.handle_api_status()
        elif self.path == "/api/mosdns/logs":
            self.handle_mosdns_logs()
        else:
            if self.path in ("/", "/index.html"):
                self.path = "/index.html"
            super().do_GET()

    def handle_api_status(self):
        # Parallel collection of all components
        results = {}
        with ThreadPoolExecutor(max_workers=8) as executor:
            fut_ros = executor.submit(get_routeros_metrics)
            fut_mos = executor.submit(get_mosdns_metrics)
            fut_sb = executor.submit(get_singbox_metrics)
            fut_daed = executor.submit(get_daed_metrics)
            fut_sys = executor.submit(get_system_stats)
            fut_ha = executor.submit(get_keepalived_metrics)
            fut_pve = executor.submit(lambda: check_tcp(CONFIG.get("pve", {}).get("host", "10.10.11.2"), CONFIG.get("pve", {}).get("port", 8006), 0.5))
            fut_ip = executor.submit(get_public_ip_info)

            results["routeros"] = fut_ros.result()
            results["mosdns"] = fut_mos.result()
            results["singbox"] = fut_sb.result()
            results["daed"] = fut_daed.result()
            results["system"] = fut_sys.result()
            results["keepalived"] = fut_ha.result()
            results["pve"] = fut_pve.result()
            results["public_ip"] = fut_ip.result()

        payload = {
            "timestamp": int(time.time()),
            "data": results
        }

        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.end_headers()
        self.wfile.write(body)

    def handle_mosdns_logs(self):
        log_file = CONFIG.get("mosdns", {}).get("log_file", "/etc/mosdns/mosdns.log")
        lines = []
        if os.path.exists(log_file):
            try:
                with open(log_file, "r", encoding="utf-8", errors="ignore") as f:
                    all_lines = f.readlines()
                    lines = [l.strip() for l in all_lines[-60:]]
            except Exception as e:
                lines = [f"读取日志失败: {e}"]
        else:
            lines = ["日志文件未找到: " + log_file]

        body = json.dumps({"lines": lines}, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # Silent server to prevent disk thrashing
        pass

def main():
    port = CONFIG.get("port", 8888)
    print(f"🚀 HomeNet Portal 2.0 (Homepage Style) running on 0.0.0.0:{port}...")
    server = ThreadingHTTPServer(("0.0.0.0", port), PortalHandler)
    server.serve_forever()

if __name__ == "__main__":
    main()
