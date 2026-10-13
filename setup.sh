#!/usr/bin/env bash
# ==============================================================================
# Project: singbox-mosdns-daed-router
# Script: setup.sh (Debian 12 旁路由核心服务一键全自动部署脚本)
# Description: 全自动完成 MosDNS v5 + Sing-box 1.14+ + MetaCubeXD + daed eBPF 安装调优
# Repository: https://github.com/luckyjamesriver/singbox-mosdns-daed-router
# License: MIT
# ==============================================================================

set -e

# --- Color Constants ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PURPLE="\033[35m"
CYAN="\033[1;36m"
PLAIN="\033[0m"

info()    { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
error()   { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; }
tip()     { echo -e "${BLUE}[TIP]${PLAIN} $*"; }
success() { echo -e "${CYAN}[SUCCESS]${PLAIN} $*"; }
title()   { echo -e "\n${PURPLE}====================================================${PLAIN}\n${PURPLE}  $*${PLAIN}\n${PURPLE}====================================================${PLAIN}"; }

# --- Check Environment ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 用户运行！请执行: sudo -i 或 sudo bash $0"
        exit 1
    fi
}

check_debian() {
    if [[ ! -f /etc/os-release ]]; then
        error "无法识别操作系统，仅支持 Debian 12 (Bookworm)！"
        exit 1
    fi
    source /etc/os-release
    if [[ "${ID}" != "debian" ]]; then
        error "当前操作系统为 ${NAME} (${ID})，本项目专为 Debian 12 旁路由精简优化！"
        exit 1
    fi
}

# --- 1. 环境探查与确认 ---
detect_environment() {
    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64|amd64)
            PKG_ARCH="amd64"
            DAED_ARCH="x86_64"
            ;;
        aarch64|arm64)
            PKG_ARCH="arm64"
            DAED_ARCH="arm64"
            ;;
        *)
            error "暂不支持的 CPU 架构: ${ARCH}"
            exit 1
            ;;
    esac

    LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -n 1 || ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
    GATEWAY_IP=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -n 1 || echo "10.10.11.1")
    INTERFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n 1 || echo "ens18")

    clear
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "${GREEN}      Debian 12 旁路由核心服务一键全自动部署工具      ${PLAIN}"
    echo -e "${BLUE}  GitHub: https://github.com/luckyjamesriver/singbox-mosdns-daed-router${PLAIN}"
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "系统环境探查结果:"
    echo -e "  - 操作系统版本  : ${GREEN}Debian ${VERSION_ID:-12} (${PKG_ARCH})${PLAIN}"
    echo -e "  - 旁路由静态 IP : ${GREEN}${LOCAL_IP}${PLAIN}"
    echo -e "  - 活动网络接口  : ${GREEN}${INTERFACE}${PLAIN}"
    echo -e "  - 主路由网关 IP : ${GREEN}${GATEWAY_IP}${PLAIN}"
    echo ""
    echo -e "${CYAN}将自动安装并配置以下全套组件:${PLAIN}"
    echo -e "  1. 🛠️  Linux 内核调优 (开启 IPv4 转发, BBR 拥塞控制, eBPF 解锁, 清理 53 端口冲突)"
    echo -e "  2. 🌐 MosDNS v5.3+ (国内外智能分流, 阿里/淘宝直连规则, 监听 :53)"
    echo -e "  3. ⚡ Sing-box 1.14+ (Socks5 :7891 进站, MetaCubeXD :9090 面板 + 每日自动更新)"
    echo -e "  4. 🚀 daed v1.27+ (eBPF 透明代理路由守护, 监听 :2023 WebUI)"
    echo -e "----------------------------------------------------"

    read -r -p "确认开始一键全自动部署？[Y/n]: " confirm < /dev/tty
    if [[ "${confirm}" == "n" || "${confirm}" == "N" ]]; then
        warn "已取消部署。"
        exit 0
    fi
}

# --- 2. 系统依赖与内核底层调优 ---
optimize_system() {
    title "1/4 正在配置系统基础依赖与内核优化"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends         curl wget jq tar unzip ca-certificates iproute2 git cron

    # 1. 释放 53 端口 (禁用 systemd-resolved)
    info "检测并释放 53 端口 (停用并禁用 systemd-resolved)..."
    if systemctl is-active --quiet systemd-resolved 2>/dev/null || systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        rm -f /etc/resolv.conf
        echo -e "nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver ${GATEWAY_IP}" > /etc/resolv.conf
    fi

    # 2. 内核参数调优 (IP 转发 + BBR + 网络栈扩容)
    info "写入 Linux 内核网络转发与 BBR 参数..."
    cat > /etc/sysctl.d/99-side-router.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
EOF
    sysctl --system >/dev/null 2>&1 || true

    # 3. 解除 eBPF 内存锁限制
    info "配置 eBPF memlock unlimited 限制..."
    cat > /etc/security/limits.d/99-daed.conf << 'EOF'
* soft memlock unlimited
* hard memlock unlimited
root soft memlock unlimited
root hard memlock unlimited
EOF

    success "系统基础依赖与内核调优完成！"
}

# --- 3. 部署 MosDNS v5.3+ ---
install_mosdns() {
    title "2/4 正在部署 MosDNS 国内外智能分流服务"

    mkdir -p /etc/mosdns/rules
    local tmp_dir="/tmp/mosdns_install"
    rm -rf "${tmp_dir}"
    mkdir -p "${tmp_dir}"

    info "从 GitHub 获取最新稳定版 MosDNS..."
    local mosdns_url
    mosdns_url=$(curl -fsSL https://api.github.com/repos/IrineSistiana/mosdns/releases/latest 2>/dev/null | jq -r ".assets[] | select(.name=="mosdns-linux-${PKG_ARCH}.zip") | .browser_download_url" || true)
    if [[ -z "${mosdns_url}" || "${mosdns_url}" == "null" ]]; then
        mosdns_url="https://github.com/IrineSistiana/mosdns/releases/download/v5.3.4/mosdns-linux-${PKG_ARCH}.zip"
    fi

    wget -qO "${tmp_dir}/mosdns.zip" "${mosdns_url}"
    unzip -qo "${tmp_dir}/mosdns.zip" -d "${tmp_dir}"
    mv -f "${tmp_dir}/mosdns" /usr/local/bin/mosdns
    chmod +x /usr/local/bin/mosdns
    rm -rf "${tmp_dir}"

    info "下载并预置国内/国外/阿里/淘宝分流规则库..."
    curl -fsSL https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt -o /etc/mosdns/rules/geosite_cn.txt 2>/dev/null || touch /etc/mosdns/rules/geosite_cn.txt
    curl -fsSL https://raw.githubusercontent.com/Hackl0us/GeoIP2-CN/release/CN-ip-cidr.txt -o /etc/mosdns/rules/geoip_cn.txt 2>/dev/null || touch /etc/mosdns/rules/geoip_cn.txt
    curl -fsSL https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt -o /etc/mosdns/rules/geosite_geolocation-\!cn.txt 2>/dev/null || touch /etc/mosdns/rules/geosite_geolocation-\!cn.txt
    curl -fsSL https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/apple.txt -o /etc/mosdns/rules/geosite_apple.txt 2>/dev/null || touch /etc/mosdns/rules/geosite_apple.txt
    curl -fsSL https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/reject-list.txt -o /etc/mosdns/rules/reject-list.txt 2>/dev/null || touch /etc/mosdns/rules/reject-list.txt
    touch /etc/mosdns/rules/geosite_byteplus.txt
    touch /etc/mosdns/rules/ai-proxy.txt
    touch /etc/mosdns/rules/adblock.txt

    # 写入强制国内直连域名 (含阿里/淘宝全系、金融与本地资产)
    cat > /etc/mosdns/rules/force-cn.txt << 'EOF'
taobao.com
taobaocdn.com
tmall.com
tmall.hk
tbcdn.cn
tbcache.com
alicdn.com
aliimg.com
alipay.com
alipayobjects.com
alibaba.com
alibabagroup.com
alibabadns.com
queniuak.com
mmstat.com
split.io
jamesho.online
hofamilynet.online
EOF

    # 写入标准 MosDNS 配置文件
    info "生成 MosDNS 高性能分流配置 (/etc/mosdns/config.yaml)..."
    cat > /etc/mosdns/config.yaml << EOF
log:
  level: info
  file: "/etc/mosdns/mosdns.log"

plugins:
  # 1. 内存缓存 (20万级大容量高速缓存)
  - tag: cache
    type: cache
    args:
      size: 204800
      lazy_cache_ttl: 86400

  # 2. 域名与 IP 规则集
  - tag: cn_domain
    type: domain_set
    args:
      exps: ["lan", "local", "arpa"]
      files:
        - "/etc/mosdns/rules/force-cn.txt"
        - "/etc/mosdns/rules/geosite_cn.txt"

  - tag: non_cn_domain
    type: domain_set
    args:
      files:
        - "/etc/mosdns/rules/geosite_geolocation-!cn.txt"
        - "/etc/mosdns/rules/ai-proxy.txt"

  - tag: apple_domain
    type: domain_set
    args:
      files:
        - "/etc/mosdns/rules/geosite_apple.txt"

  - tag: byte_domain
    type: domain_set
    args:
      files:
        - "/etc/mosdns/rules/geosite_byteplus.txt"

  - tag: reject_domain
    type: domain_set
    args:
      files:
        - "/etc/mosdns/rules/reject-list.txt"
        - "/etc/mosdns/rules/adblock.txt"

  - tag: cn_ip
    type: ip_set
    args:
      files:
        - "/etc/mosdns/rules/geoip_cn.txt"

  # 3. 上游 DNS 服务器
  # 国内 DNS（直连）
  - tag: dns_cn
    type: forward
    args:
      concurrent: 3
      upstreams:
        - addr: "${GATEWAY_IP}"
        - addr: "223.5.5.5"
        - addr: "119.29.29.29"

  # 国内备用 (TCP + DoH)
  - tag: dns_cn_backup
    type: forward
    args:
      concurrent: 3
      upstreams:
        - addr: "tcp://223.6.6.6"
        - addr: "https://doh.pub/dns-query"
          dial_addr: "1.12.12.12"
        - addr: "https://doh.pub/dns-query"
          dial_addr: "120.53.53.53"

  # 国外 DNS (走代理)
  - tag: dns_proxy
    type: forward
    args:
      concurrent: 3
      upstreams:
        - addr: "tcp://1.1.1.1"
        - addr: "tcp://8.8.8.8"
        - addr: "tcp://9.9.9.9"

  # 国外备用
  - tag: dns_proxy2
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "tcp://8.8.4.4"
        - addr: "tcp://1.0.0.1"

  # 抖音火山 CDN 专属
  - tag: dns_douyin
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "180.184.1.1"
        - addr: "180.184.2.2"

  # 4. 容灾与分流策略
  - tag: apple_strategy
    type: fallback
    args:
      primary: dns_cn
      secondary: dns_cn_backup
      threshold: 700
      always_standby: true

  - tag: douyin_strategy
    type: fallback
    args:
      primary: dns_douyin
      secondary: dns_cn
      threshold: 200
      always_standby: true

  - tag: final_strategy
    type: fallback
    args:
      primary: dns_proxy
      secondary: dns_proxy2
      threshold: 700
      always_standby: true

  # 5. 主执行逻辑序列
  - tag: main
    type: sequence
    args:
      - exec: \$cache
      - matches: has_resp
        exec: accept

      # 屏蔽 IPv6 AAAA 记录 (防泄漏与抢答)
      - matches: qtype 28
        exec: reject 0

      # 屏蔽 HTTPS RR (防止 ECH 绕过)
      - matches: qtype 12 65
        exec: reject 3

      # 广告拦截
      - matches: qname \$reject_domain
        exec: reject 3

      # Apple 优化
      - matches: qname \$apple_domain
        exec: \$apple_strategy
      - matches: has_resp
        exec: accept

      # 抖音 CDN 优化
      - matches: qname \$byte_domain
        exec: \$douyin_strategy
      - matches: has_resp
        exec: accept

      # 国内域名直连
      - matches: qname \$cn_domain
        exec: \$dns_cn
      - matches: has_resp
        exec: accept

      # 国外域名代理
      - matches: qname \$non_cn_domain
        exec: \$dns_proxy
      - exec: ttl 300-3600
      - matches: has_resp
        exec: accept

      # 未知域名：国内 DNS 优先，国内 IP 则直接采纳
      - exec: \$dns_cn
      - matches: resp_ip \$cn_ip
        exec: accept

      # 未知非国内 IP 丢弃，切换国外代理 DNS 兜底
      - exec: drop_resp
      - exec: \$final_strategy
      - exec: ttl 300-3600
      - matches: has_resp
        exec: accept

      - exec: reject 3

  # 6. 监听端口 (TCP & UDP 53)
  - tag: udp_server
    type: udp_server
    args:
      entry: main
      listen: "0.0.0.0:53"

  - tag: tcp_server
    type: tcp_server
    args:
      entry: main
      listen: "0.0.0.0:53"
EOF

    # 配置 Systemd 服务
    cat > /etc/systemd/system/mosdns.service << 'EOF'
[Unit]
Description=MosDNS Daemon
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/mosdns
ExecStart=/usr/local/bin/mosdns start -c /etc/mosdns/config.yaml -d /etc/mosdns
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mosdns --now

    # 配置规则库自动更新脚本与定时任务
    cat > /etc/mosdns/mos_rule_update.sh << 'EOF'
#!/bin/bash
set -e
download() {
  local url="$1"
  local dest="$2"
  local tmp="$dest.tmp"
  if curl -fsSL "$url" -o "$tmp"; then
    mv -f "$tmp" "$dest"
  fi
}
download "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt" "/etc/mosdns/rules/geosite_cn.txt"
download "https://raw.githubusercontent.com/Hackl0us/GeoIP2-CN/release/CN-ip-cidr.txt" "/etc/mosdns/rules/geoip_cn.txt"
download "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt" "/etc/mosdns/rules/geosite_geolocation-!cn.txt"
download "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/reject-list.txt" "/etc/mosdns/rules/reject-list.txt"
download "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/apple.txt" "/etc/mosdns/rules/geosite_apple.txt"
systemctl restart mosdns
EOF
    chmod +x /etc/mosdns/mos_rule_update.sh
    (crontab -l 2>/dev/null | grep -v 'mos_rule_update.sh' ; echo "0 4 * * * /etc/mosdns/mos_rule_update.sh >/dev/null 2>&1") | crontab -

    # 配置 MosDNS 核心平滑升级脚本 (/usr/local/bin/update_mosdns.sh)
    info "配置 MosDNS 核心平滑升级脚本 (/usr/local/bin/update_mosdns.sh)..."
    cat > /usr/local/bin/update_mosdns.sh << 'EOF'
#!/usr/bin/env bash
# ==============================================================================
# Script: update_mosdns.sh
# Description: MosDNS 核心全自动安全平滑升级脚本 (自动匹配架构、多源容灾、备份与回滚)
# Project: singbox-mosdns-daed-router
# ==============================================================================

set -eo pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PLAIN="\033[0m"

log_info()  { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
log_error() { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${PLAIN} $*"; }

BIN_FILE="/usr/local/bin/mosdns"
CONFIG_FILE="/etc/mosdns/config.yaml"
BACKUP_DIR="/var/backups/mosdns"
TMP_DIR="/tmp/mosdns_update"
LOG_FILE="/var/log/mosdns_update.log"

FORCE=false
CHECK_ONLY=false

usage() {
    echo "用法: sudo $0 [选项]"
    echo "选项:"
    echo "  -c, --check    仅检查是否有新版本，不执行升级"
    echo "  -f, --force    即使已是最新版本也强制重新下载更新并验证"
    echo "  -h, --help     显示帮助信息"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--check) CHECK_ONLY=true; shift ;;
        -f|--force) FORCE=true; shift ;;
        -h|--help) usage ;;
        *) log_error "未知参数: $1"; usage ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    log_error "此脚本必须以 root 权限运行！请执行: sudo $0"
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log_step "=== [$(date '+%Y-%m-%d %H:%M:%S')] 开始检查 MosDNS 核心版本 ==="

# 1. 架构识别
ARCH=$(uname -m)
case "${ARCH}" in
    x86_64|amd64)   MOSDNS_ARCH="amd64" ;;
    aarch64|arm64)  MOSDNS_ARCH="arm64" ;;
    *) log_error "暂不支持的 CPU 架构: ${ARCH}"; exit 1 ;;
esac

# 2. 获取当前已安装版本
CURRENT_VER="未安装"
if [[ -f "$BIN_FILE" ]]; then
    CURRENT_VER=$("$BIN_FILE" version 2>/dev/null | awk '{print $2}' || "$BIN_FILE" version 2>/dev/null | head -n 1)
    [[ -z "$CURRENT_VER" ]] && CURRENT_VER="未知"
fi
log_info "当前已安装版本: ${CYAN}${CURRENT_VER}${PLAIN}"

# 3. 通过 GitHub API 获取最新 Release 版本号
log_step "正在从 GitHub 获取 MosDNS 最新发布版本..."
API_URL="https://api.github.com/repos/IrineSistiana/mosdns/releases/latest"

fetch_latest_tag() {
    local res=""
    res=$(curl -fsSL -x socks5h://127.0.0.1:7891 --connect-timeout 5 --max-time 15 "$API_URL" 2>/dev/null || true)
    if [[ -z "$res" ]]; then
        res=$(curl -fsSL --connect-timeout 5 --max-time 15 "$API_URL" 2>/dev/null || true)
    fi
    if [[ -z "$res" ]]; then
        res=$(curl -fsSL --connect-timeout 5 --max-time 15 "https://ghfast.top/$API_URL" 2>/dev/null || true)
    fi
    echo "$res" | grep -m 1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

LATEST_TAG=$(fetch_latest_tag)
if [[ -z "$LATEST_TAG" ]]; then
    log_error "获取 GitHub 最新版本失败，请检查网络或 GitHub 连通性！"
    exit 1
fi
log_info "GitHub 最新稳定版本: ${CYAN}${LATEST_TAG}${PLAIN}"

if [[ "$CHECK_ONLY" == true ]]; then
    if [[ "$CURRENT_VER" == "$LATEST_TAG" || "$CURRENT_VER" == "${LATEST_TAG#v}" ]]; then
        log_info "当前已是最新版本，无需升级。"
    else
        log_warn "检测到新版本可用: ${CURRENT_VER} -> ${LATEST_TAG}"
    fi
    exit 0
fi

if [[ ("$CURRENT_VER" == "$LATEST_TAG" || "$CURRENT_VER" == "${LATEST_TAG#v}") && "$FORCE" != true ]]; then
    log_info "当前 MosDNS 已是最新版本 (${CURRENT_VER})，无需重复升级。"
    exit 0
fi

# 4. 构造下载链接 (多源容灾)
ZIP_NAME="mosdns-linux-${MOSDNS_ARCH}.zip"
RELEASE_URL="https://github.com/IrineSistiana/mosdns/releases/download/${LATEST_TAG}/${ZIP_NAME}"
MIRROR_URL="https://ghfast.top/${RELEASE_URL}"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

log_step "正在下载 MosDNS 核心软件包 (${ZIP_NAME})..."
download_success=false

if curl -fsSL -x socks5h://127.0.0.1:7891 "$RELEASE_URL" -o "$TMP_DIR/$ZIP_NAME" --connect-timeout 10 --max-time 60 2>/dev/null; then
    log_info "通过本地代理通道下载成功。"
    download_success=true
elif curl -fsSL "$MIRROR_URL" -o "$TMP_DIR/$ZIP_NAME" --connect-timeout 10 --max-time 60 2>/dev/null; then
    log_info "通过加速镜像通道下载成功。"
    download_success=true
elif curl -fsSL "$RELEASE_URL" -o "$TMP_DIR/$ZIP_NAME" --connect-timeout 10 --max-time 60 2>/dev/null; then
    log_info "直连通道下载成功。"
    download_success=true
fi

if [[ "$download_success" != true || ! -s "$TMP_DIR/$ZIP_NAME" ]]; then
    log_error "下载 MosDNS 核心二进制失败，请检查网络！"
    rm -rf "$TMP_DIR"
    exit 1
fi

# 5. 解压并验证可执行性
log_step "解压并验证软件包完整性..."
unzip -q -o "$TMP_DIR/$ZIP_NAME" -d "$TMP_DIR/extracted"
NEW_BIN="$TMP_DIR/extracted/mosdns"

if [[ ! -f "$NEW_BIN" ]]; then
    log_error "解压后未找到有效 mosdns 二进制文件！"
    rm -rf "$TMP_DIR"
    exit 1
fi

chmod +x "$NEW_BIN"

if ! "$NEW_BIN" version >/dev/null 2>&1; then
    log_error "新版本 mosdns 二进制在当前系统无法正常执行！已中止升级。"
    rm -rf "$TMP_DIR"
    exit 1
fi

# 6. 备份现有版本
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
if [[ -f "$BIN_FILE" ]]; then
    cp -pf "$BIN_FILE" "$BACKUP_DIR/mosdns_${CURRENT_VER}_${TIMESTAMP}"
    cp -pf "$BIN_FILE" "$BACKUP_DIR/mosdns.bak"
    log_info "已备份旧版二进制文件至: $BACKUP_DIR/mosdns.bak"
fi

# 7. 部署新二进制
log_step "替换并安装新版本二进制至 $BIN_FILE ..."
cp -pf "$NEW_BIN" "$BIN_FILE"
chmod +x "$BIN_FILE"
rm -rf "$TMP_DIR"

NEW_VER=$("$BIN_FILE" version 2>/dev/null | awk '{print $2}' || "$BIN_FILE" version 2>/dev/null | head -n 1)

# 8. 重启并验证服务状态
log_step "重启 MosDNS 服务并检验运行状态..."
systemctl daemon-reload
systemctl restart mosdns

sleep 1
if systemctl is-active --quiet mosdns; then
    log_info "🎉 MosDNS 服务重启成功，状态: active (running)"
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e "${GREEN}  MosDNS 成功平滑升级至: ${NEW_VER}${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}"
else
    log_error "服务重启失败，正在执行自动回滚..."
    journalctl -u mosdns -n 20 --no-pager
    if [[ -f "$BACKUP_DIR/mosdns.bak" ]]; then
        cp -pf "$BACKUP_DIR/mosdns.bak" "$BIN_FILE"
        systemctl restart mosdns
        log_warn "已回滚至旧版本 (${CURRENT_VER})。"
    fi
    exit 1
fi
EOF
    chmod +x /usr/local/bin/update_mosdns.sh

    success "MosDNS 服务与升级脚本 (/usr/local/bin/update_mosdns.sh) 已就绪！"
}

# --- 4. 部署 Sing-box 1.14+ 与 MetaCubeXD 面板 ---
install_singbox() {
    title "3/4 正在部署 Sing-box 核心与 MetaCubeXD 监控面板"

    # 1. 导入 SagerNet 官方 APT deb822 源
    info "配置 SagerNet 官方 deb822 软件源..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    chmod a+r /etc/apt/keyrings/sagernet.asc

    cat > /etc/apt/sources.list.d/sagernet.sources << 'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

    apt-get update -y
    apt-get install -y sing-box

    # 2. 部署 MetaCubeXD 面板
    info "部署 MetaCubeXD Web 仪表板与每日自动更新机制..."
    mkdir -p /etc/sing-box/ui
    curl -fsSL https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip -o /tmp/metacubexd.zip 2>/dev/null || true
    if [[ -f /tmp/metacubexd.zip ]]; then
        unzip -qo /tmp/metacubexd.zip -d /tmp/metacubexd_tmp
        cp -rf /tmp/metacubexd_tmp/metacubexd-gh-pages/* /etc/sing-box/ui/ 2>/dev/null || true
        rm -rf /tmp/metacubexd.zip /tmp/metacubexd_tmp
    fi

    # 自动更新脚本
    cat > /usr/local/bin/update_metacubexd.sh << 'EOF'
#!/usr/bin/env bash
set -e
UI_DIR="/etc/sing-box/ui"
TMP_ZIP="/tmp/metacubexd.zip"
TMP_DIR="/tmp/metacubexd_update"

mkdir -p "${UI_DIR}"
rm -rf "${TMP_ZIP}" "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

if curl -fsSL "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip" -o "${TMP_ZIP}"; then
    unzip -qo "${TMP_ZIP}" -d "${TMP_DIR}"
    cp -rf "${TMP_DIR}/metacubexd-gh-pages/"* "${UI_DIR}/"
    rm -rf "${TMP_ZIP}" "${TMP_DIR}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] MetaCubeXD updated successfully." >> /var/log/metacubexd_update.log
fi
EOF
    chmod +x /usr/local/bin/update_metacubexd.sh

    # 配置每日凌晨 03:00 自动更新
    (crontab -l 2>/dev/null | grep -v 'update_metacubexd.sh' ; echo "0 3 * * * /usr/local/bin/update_metacubexd.sh >/dev/null 2>&1") | crontab -

    # 配置 Sing-box 核心平滑升级脚本 (/usr/local/bin/update_singbox.sh)
    info "配置 Sing-box 核心平滑升级脚本 (/usr/local/bin/update_singbox.sh)..."
    cat > /usr/local/bin/update_singbox.sh << 'EOF'
#!/usr/bin/env bash
# ==============================================================================
# Script: update_singbox.sh
# Description: Sing-box 核心全自动安全平滑升级脚本 (带预检、备份、语法校验与自动回滚)
# Project: singbox-mosdns-daed-router
# ==============================================================================

set -eo pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PLAIN="\033[0m"

log_info()  { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
log_error() { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${PLAIN} $*"; }

CONFIG_FILE="/etc/sing-box/config.json"
BIN_FILE="/usr/bin/sing-box"
BACKUP_DIR="/var/backups/sing-box"
LOG_FILE="/var/log/singbox_update.log"

FORCE=false
CHECK_ONLY=false

usage() {
    echo "用法: sudo $0 [选项]"
    echo "选项:"
    echo "  -c, --check    仅检查是否有新版本，不执行升级"
    echo "  -f, --force    即使已是最新版本也强制重新更新并验证"
    echo "  -h, --help     显示帮助信息"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--check) CHECK_ONLY=true; shift ;;
        -f|--force) FORCE=true; shift ;;
        -h|--help) usage ;;
        *) log_error "未知参数: $1"; usage ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    log_error "此脚本必须以 root 权限运行！请执行: sudo $0"
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log_step "=== [$(date '+%Y-%m-%d %H:%M:%S')] 开始检查 Sing-box 核心版本 ==="

# 1. 获取当前版本
CURRENT_VER="未安装"
if command -v sing-box >/dev/null 2>&1; then
    CURRENT_VER=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
fi
log_info "当前已安装版本: ${CYAN}${CURRENT_VER}${PLAIN}"

# 2. 刷新 APT 软件源缓存
log_step "正在刷新 SagerNet 官方 APT 软件源索引..."
if ! apt-get update -o Dir::Etc::sourcelist="sources.list.d/sagernet.sources" -o Dir::Etc::sourceparts="-" >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
fi

# 3. 获取 APT 可用候选版本
CANDIDATE_VER=$(apt-cache policy sing-box 2>/dev/null | grep 'Candidate:' | awk '{print $2}')
if [[ -z "$CANDIDATE_VER" || "$CANDIDATE_VER" == "(none)" ]]; then
    log_error "无法从 APT 源中获取 sing-box 候选版本，请检查 /etc/apt/sources.list.d/sagernet.sources 配置！"
    exit 1
fi
log_info "官方软件源最新版本: ${CYAN}${CANDIDATE_VER}${PLAIN}"

if [[ "$CHECK_ONLY" == true ]]; then
    if [[ "$CURRENT_VER" == "$CANDIDATE_VER" ]]; then
        log_info "当前已是最新版本，无需升级。"
    else
        log_warn "检测到新版本可用: ${CURRENT_VER} -> ${CANDIDATE_VER}"
    fi
    exit 0
fi

if [[ "$CURRENT_VER" == "$CANDIDATE_VER" && "$FORCE" != true ]]; then
    log_info "当前 Sing-box 已是最新版本 (${CURRENT_VER})，无需重复升级。"
    exit 0
fi

# 4. 升级前安全预检：验证现有配置文件合法性
if [[ -f "$CONFIG_FILE" ]]; then
    log_step "执行升级前预检：校验当前配置语法合法性..."
    if ! sing-box check -c "$CONFIG_FILE"; then
        log_error "当前配置文件存在语法错误，已中止升级，防止升级后服务故障！"
        exit 1
    fi
    log_info "配置文件预检通过。"
fi

# 5. 备份旧版本二进制与配置
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
if [[ -f "$BIN_FILE" ]]; then
    cp -pf "$BIN_FILE" "$BACKUP_DIR/sing-box_${CURRENT_VER}_${TIMESTAMP}"
    cp -pf "$BIN_FILE" "$BACKUP_DIR/sing-box.bak"
    log_info "已备份旧版二进制文件至: $BACKUP_DIR/sing-box.bak"
fi
if [[ -f "$CONFIG_FILE" ]]; then
    cp -pf "$CONFIG_FILE" "$BACKUP_DIR/config_${TIMESTAMP}.json"
fi

# 6. 执行 APT 升级
log_step "正在执行 APT 升级安装 sing-box..."
apt-get install --only-upgrade -y sing-box

NEW_VER=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
log_info "二进制升级完成，当前版本: ${CYAN}${NEW_VER}${PLAIN}"

# 7. 升级后配置兼容性校验与故障自动回滚
if [[ -f "$CONFIG_FILE" ]]; then
    log_step "执行升级后兼容性校验..."
    if ! sing-box check -c "$CONFIG_FILE"; then
        log_error "⚠️ 新版本 sing-box 对当前配置文件校验失败！触发自动回滚..."
        if [[ -f "$BACKUP_DIR/sing-box.bak" ]]; then
            cp -pf "$BACKUP_DIR/sing-box.bak" "$BIN_FILE"
            log_warn "已恢复至旧版二进制文件 (${CURRENT_VER})。"
        fi
        systemctl restart sing-box || true
        exit 1
    fi
    log_info "新版本与当前配置文件完全兼容！"
fi

# 8. 重启并验证 Systemd 服务
log_step "重启 sing-box 服务并检验运行状态..."
systemctl daemon-reload
systemctl restart sing-box

sleep 1
if systemctl is-active --quiet sing-box; then
    log_info "🎉 Sing-box 服务重启成功，状态: active (running)"
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e "${GREEN}  Sing-box 成功平滑升级至: ${NEW_VER}${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}"
else
    log_error "服务启动失败，查看故障日志:"
    journalctl -u sing-box -n 20 --no-pager
    if [[ -f "$BACKUP_DIR/sing-box.bak" ]]; then
        log_warn "正在自动回滚旧版本..."
        cp -pf "$BACKUP_DIR/sing-box.bak" "$BIN_FILE"
        systemctl restart sing-box
    fi
    exit 1
fi
EOF
    chmod +x /usr/local/bin/update_singbox.sh

    # 3. 写入 Sing-box 基础配置文件 (若无则生成模板)
    if [[ ! -f /etc/sing-box/config.json ]]; then
        info "生成 Sing-box 默认核心配置 (/etc/sing-box/config.json)..."
        cat > /etc/sing-box/config.json << 'EOF'
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:9090",
      "external_ui": "ui",
      "external_ui_download_url": "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip",
      "external_ui_download_detour": "direct",
      "default_mode": "rule"
    },
    "cache_file": {
      "enabled": true
    }
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "0.0.0.0",
      "listen_port": 7891
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "0.0.0.0",
      "listen_port": 7890
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["socks-in", "mixed-in"],
        "outbound": "direct"
      }
    ],
    "auto_detect_interface": true
  }
}
EOF
    fi

    systemctl daemon-reload
    systemctl enable sing-box --now
    systemctl restart sing-box
    success "Sing-box 1.14+ 与 MetaCubeXD 面板已就绪 (监听 :7891 / :9090)！"
}

# --- 5. 部署 daed v1.27+ ---
install_daed() {
    title "4/4 正在部署 daed eBPF 透明代理守护服务"

    local daed_deb="/tmp/daed.deb"
    rm -f "${daed_deb}"

    info "下载 daed v1.27.0 官方安装包 (${DAED_ARCH})..."
    wget -qO "${daed_deb}" "https://github.com/daeuniverse/daed/releases/download/v1.27.0/installer-daed-linux-${DAED_ARCH}.deb" || {
        error "下载 daed 安装包失败，请检查网络！"
        exit 1
    }

    info "安装 daed deb 软件包..."
    dpkg -i "${daed_deb}"
    rm -f "${daed_deb}"

    systemctl daemon-reload
    systemctl enable daed --now
    systemctl restart daed

    success "daed 服务已成功启动并在 0.0.0.0:2023 开启 WebUI 管理面板！"
}

# --- 6. 输出完工看板 ---
show_summary() {
    clear
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "${GREEN}  🎉 恭喜！Debian 12 旁路由核心服务已全部全自动部署完成！ ${PLAIN}"
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo ""
    echo -e "${CYAN}【已就绪的核心服务清单】:${PLAIN}"
    echo -e "  - 🚀 ${GREEN}daed eBPF 管理面板${PLAIN} : ${YELLOW}http://${LOCAL_IP}:2023${PLAIN}"
    echo -e "  - 📊 ${GREEN}MetaCubeXD 监控面板${PLAIN} : ${YELLOW}http://${LOCAL_IP}:9090/ui${PLAIN}"
    echo -e "  - 🌐 ${GREEN}MosDNS 分流解析端口${PLAIN} : ${YELLOW}${LOCAL_IP}:53${PLAIN} (TCP/UDP)"
    echo -e "  - ⚡ ${GREEN}Sing-box 代理入站端口${PLAIN} : ${YELLOW}${LOCAL_IP}:7891${PLAIN} (Socks5)"
    echo ""
    echo -e "${CYAN}【已配置的平滑升级与运维工具】:${PLAIN}"
    echo -e "  - ⚡ 升级 Sing-box 核心 : ${YELLOW}sudo /usr/local/bin/update_singbox.sh${PLAIN} (--check 检查, --force 强制)"
    echo -e "  - 🌐 升级 MosDNS 核心   : ${YELLOW}sudo /usr/local/bin/update_mosdns.sh${PLAIN} (--check 检查, --force 强制)"
    echo -e "  - 📊 升级 Web 仪表板    : ${YELLOW}sudo /usr/local/bin/update_metacubexd.sh${PLAIN}"
    echo -e "  - 📋 升级 DNS 规则库    : ${YELLOW}sudo /etc/mosdns/mos_rule_update.sh${PLAIN}"
    echo ""
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}【接下来您只需完成两步】:${PLAIN}"
    echo -e "  ${GREEN}第一步：浏览器打开 daed 网页管理面板${PLAIN}"
    echo -e "    1. 访问: ${YELLOW}http://${LOCAL_IP}:2023${PLAIN} (初次打开设置管理员账号密码)"
    echo -e "    2. 在【接口】中选择: ${GREEN}${INTERFACE}${PLAIN}"
    echo -e "    3. 在【连接选项】中：拨号模式推荐选择: ${CYAN}domain${PLAIN} (极速低负载)"
    echo -e "    4. 在【DNS】中：上游填写: ${CYAN}tcp+udp://127.0.0.1:53${PLAIN}"
    echo -e "    5. 添加本地 Sing-box (socks5://127.0.0.1:7891) 作为出站节点"
    echo -e "    6. 在【路由】中配置分流规则 (pname(mosdns) -> must_rules, geosite:cn/geoip:cn -> direct)"
    echo -e "    7. 点击右上角运行按钮启动 eBPF 内核级透明分流！"
    echo ""
    echo -e "  ${GREEN}第二步：在 RouterOS 主路由配置 DHCP (让局域网设备无缝享受加速)${PLAIN}"
    echo -e "    - 将 RouterOS DHCP Option 3 (Gateway) 指向 : ${GREEN}${LOCAL_IP}${PLAIN}"
    echo -e "    - 将 RouterOS DHCP Option 6 (DNS Server) 指向: ${GREEN}${LOCAL_IP}${PLAIN}"
    echo -e "----------------------------------------------------"
    echo ""
}

# --- Main Entry ---
check_root
check_debian
detect_environment
optimize_system
install_mosdns
install_singbox
install_daed
show_summary
