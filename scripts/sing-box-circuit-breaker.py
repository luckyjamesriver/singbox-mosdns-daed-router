#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sing-box Protocol Circuit Breaker (协议熔断与自我保护机制)
- 监控各代理协议连通性，一旦某协议被拦截/连续超时，自动将其从策略组剔除
- 彻底停止向该协议端口发包，防止连带导致整台 VPS 被封
- 平滑热重载 sing-box，连接不中断
"""

import sys
import os
import json
import time
import subprocess
import urllib.request
import urllib.parse
import urllib.error

CONFIG_FILE = "/etc/sing-box/config.json"
STATE_FILE = "/etc/sing-box/breaker_state.json"
LOG_FILE = "/var/log/sing-box-breaker.log"
CLASH_API = "http://127.0.0.1:9090"

FAIL_THRESHOLD = 3                     # 连续失败 3 次触发熔断
RECOVERY_PROBE_INTERVAL = 900          # 熔断后冷却 15 分钟才低频单次试探
RECOVERY_SUCCESS_THRESHOLD = 2         # 连续 2 次试探成功才恢复
TARGET_GROUPS = ["主力线路", "备用线路"]
TEST_URL = "https://cp.cloudflare.com/generate_204"

def log(msg):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass

def load_config():
    with open(CONFIG_FILE, "r", encoding="utf-8") as f:
        return json.load(f)

def save_and_reload_config(new_cfg):
    temp_file = CONFIG_FILE + ".tmp"
    with open(temp_file, "w", encoding="utf-8") as f:
        json.dump(new_cfg, f, indent=2, ensure_ascii=False)
    
    # 语法严密检查
    check = subprocess.run(["sing-box", "check", "-c", temp_file], capture_output=True, text=True)
    if check.returncode != 0:
        log(f"CRITICAL: sing-box check failed: {check.stderr.strip()}")
        if os.path.exists(temp_file):
            os.remove(temp_file)
        return False
    
    os.replace(temp_file, CONFIG_FILE)
    # 平滑热重载
    reload_res = subprocess.run(["systemctl", "reload", "sing-box"], capture_output=True, text=True)
    if reload_res.returncode == 0:
        log("SUCCESS: sing-box reloaded smoothly with updated outbound groups.")
        return True
    else:
        log(f"ERROR: systemctl reload failed: {reload_res.stderr.strip()}")
        return False

def load_state(cfg):
    state = {}
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                state = json.load(f)
        except Exception:
            pass

    if "initial_groups" not in state:
        state["initial_groups"] = {}
        for ob in cfg.get("outbounds", []):
            if ob.get("tag") in TARGET_GROUPS:
                state["initial_groups"][ob["tag"]] = list(ob.get("outbounds", []))

    if "nodes" not in state:
        state["nodes"] = {}

    # 补齐所有管理的节点
    for group_tag, members in state["initial_groups"].items():
        for m in members:
            if m not in state["nodes"]:
                state["nodes"][m] = {
                    "group": group_tag,
                    "status": "active",       # active | tripped
                    "fail_count": 0,
                    "recovery_count": 0,
                    "last_delay": 0,
                    "tripped_at": None,
                    "last_probe_time": 0
                }
    return state

def save_state(state):
    temp = STATE_FILE + ".tmp"
    with open(temp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
    os.replace(temp, STATE_FILE)

def fetch_proxies_data():
    try:
        req = urllib.request.urlopen(f"{CLASH_API}/proxies", timeout=4)
        return json.loads(req.read().decode())
    except Exception as e:
        log(f"WARNING: Failed to fetch proxies from clash_api: {e}")
        return None

def single_probe_node(node_tag):
    """用于被熔断节点的极低频单次轻量探测"""
    try:
        url = f"{CLASH_API}/proxies/{urllib.parse.quote(node_tag)}/delay?timeout=5000&url={urllib.parse.quote(TEST_URL)}"
        req = urllib.request.urlopen(url, timeout=6)
        res = json.loads(req.read().decode())
        delay = res.get("delay", 0)
        return delay
    except Exception:
        return 0

def run_check():
    cfg = load_config()
    state = load_state(cfg)
    proxies_data = fetch_proxies_data()
    if not proxies_data:
        log("Skip check because clash_api is unreachable.")
        return

    proxies_map = proxies_data.get("proxies", {})
    now = time.time()
    config_changed = False

    # 1. 检查活跃节点
    for node_tag, ninfo in state["nodes"].items():
        group_tag = ninfo["group"]
        if ninfo["status"] == "active":
            pdata = proxies_map.get(node_tag, {})
            history = pdata.get("history", [])
            last_delay = history[-1].get("delay", 0) if history else 0
            ninfo["last_delay"] = last_delay

            if last_delay > 0:
                ninfo["fail_count"] = 0
            else:
                ninfo["fail_count"] += 1
                log(f"Node [{node_tag}] probe failed ({ninfo['fail_count']}/{FAIL_THRESHOLD})")

                if ninfo["fail_count"] >= FAIL_THRESHOLD:
                    # 检查组内剩余节点数，避免清空组
                    current_group_obs = []
                    for ob in cfg.get("outbounds", []):
                        if ob.get("tag") == group_tag:
                            current_group_obs = ob.get("outbounds", [])
                            break

                    if len(current_group_obs) > 1 and node_tag in current_group_obs:
                        log(f"CIRCUIT BREAKER TRIPPED: Disabling blocked node [{node_tag}] from [{group_tag}]!")
                        current_group_obs.remove(node_tag)
                        ninfo["status"] = "tripped"
                        ninfo["tripped_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
                        ninfo["last_probe_time"] = now
                        ninfo["recovery_count"] = 0
                        config_changed = True
                    else:
                        log(f"WARNING: [{node_tag}] failed but is the last node in [{group_tag}]. Keep it to prevent empty group.")

        elif ninfo["status"] == "tripped":
            # 2. 检查被熔断节点的恢复试探 (极低频)
            if now - ninfo.get("last_probe_time", 0) >= RECOVERY_PROBE_INTERVAL:
                log(f"Probe tripped node [{node_tag}] for possible recovery...")
                ninfo["last_probe_time"] = now
                probe_delay = single_probe_node(node_tag)
                ninfo["last_delay"] = probe_delay

                if probe_delay > 0:
                    ninfo["recovery_count"] += 1
                    log(f"Node [{node_tag}] probe SUCCESS ({ninfo['recovery_count']}/{RECOVERY_SUCCESS_THRESHOLD}, delay: {probe_delay}ms)")
                    if ninfo["recovery_count"] >= RECOVERY_SUCCESS_THRESHOLD:
                        log(f"CIRCUIT BREAKER RESTORE: Node [{node_tag}] recovered! Adding back to [{group_tag}].")
                        for ob in cfg.get("outbounds", []):
                            if ob.get("tag") == group_tag:
                                if node_tag not in ob.get("outbounds", []):
                                    ob["outbounds"].append(node_tag)
                                break
                        ninfo["status"] = "active"
                        ninfo["fail_count"] = 0
                        ninfo["tripped_at"] = None
                        config_changed = True
                else:
                    ninfo["recovery_count"] = 0
                    log(f"Node [{node_tag}] still unreachable. Keep quiet.")

    save_state(state)
    if config_changed:
        save_and_reload_config(cfg)

def manual_trip(node_tag):
    cfg = load_config()
    state = load_state(cfg)
    if node_tag not in state["nodes"]:
        print(f"Error: Node [{node_tag}] not found in managed nodes.")
        return
    ninfo = state["nodes"][node_tag]
    group_tag = ninfo["group"]

    for ob in cfg.get("outbounds", []):
        if ob.get("tag") == group_tag:
            obs = ob.get("outbounds", [])
            if len(obs) <= 1:
                print(f"Error: Cannot trip [{node_tag}], it is the last node in [{group_tag}].")
                return
            if node_tag in obs:
                obs.remove(node_tag)
            break

    ninfo["status"] = "tripped"
    ninfo["tripped_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    ninfo["last_probe_time"] = time.time()
    ninfo["recovery_count"] = 0
    save_state(state)
    if save_and_reload_config(cfg):
        print(f"Successfully tripped [{node_tag}] from [{group_tag}]. Sing-box reloaded.")

def manual_restore(target):
    cfg = load_config()
    state = load_state(cfg)
    nodes_to_restore = []
    if target == "all":
        nodes_to_restore = [k for k, v in state["nodes"].items() if v["status"] == "tripped"]
    elif target in state["nodes"]:
        nodes_to_restore = [target]
    else:
        print(f"Error: Target [{target}] not found.")
        return

    if not nodes_to_restore:
        print("No tripped nodes to restore.")
        return

    for node_tag in nodes_to_restore:
        ninfo = state["nodes"][node_tag]
        group_tag = ninfo["group"]
        for ob in cfg.get("outbounds", []):
            if ob.get("tag") == group_tag:
                obs = ob.get("outbounds", [])
                if node_tag not in obs:
                    obs.append(node_tag)
                break
        ninfo["status"] = "active"
        ninfo["fail_count"] = 0
        ninfo["tripped_at"] = None

    save_state(state)
    if save_and_reload_config(cfg):
        print(f"Successfully restored nodes: {nodes_to_restore}. Sing-box reloaded.")

def print_status():
    cfg = load_config()
    state = load_state(cfg)
    proxies_data = fetch_proxies_data() or {}
    proxies_map = proxies_data.get("proxies", {})

    print("=" * 80)
    print(f"{'Node Tag':<30} {'Group':<12} {'Status':<10} {'Delay':<8} {'Fail/Max':<10}")
    print("-" * 80)
    for node_tag, ninfo in sorted(state["nodes"].items(), key=lambda x: (x[1]["group"], x[0])):
        pdata = proxies_map.get(node_tag, {})
        history = pdata.get("history", [])
        delay_str = f"{history[-1].get('delay', 0)}ms" if history else "-"
        status = ninfo["status"].upper()
        if status == "TRIPPED":
            status_display = "\033[31mTRIPPED\033[0m"
        else:
            status_display = "\033[32mACTIVE\033[0m"
        fails = f"{ninfo['fail_count']}/{FAIL_THRESHOLD}"
        print(f"{node_tag:<30} {ninfo['group']:<12} {status_display:<19} {delay_str:<8} {fails:<10}")
    print("=" * 80)

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] == "check":
        run_check()
    elif sys.argv[1] == "status":
        print_status()
    elif sys.argv[1] == "trip" and len(sys.argv) >= 3:
        manual_trip(sys.argv[2])
    elif sys.argv[1] == "restore" and len(sys.argv) >= 3:
        manual_restore(sys.argv[2])
    else:
        print("Usage: breaker-ctl {check|status|trip <node>|restore <node|all>}")
