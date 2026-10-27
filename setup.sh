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
    mosdns_url=$(curl -fsSL https://api.github.com/repos/IrineSistiana/mosdns/releases/latest 2>/dev/null | jq -r --arg name "mosdns-linux-${PKG_ARCH}.zip" '.assets[] | select(.name==$name) | .browser_download_url' 2>/dev/null || true)
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
        - addr: "223.5.5.5"
        - addr: "119.29.29.29"
        - addr: "114.114.114.114"

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

      # 屏蔽 HTTPS RR (屏蔽 64 SVCB 与 65 HTTPS，防止 ECH 绕过)
      - matches: qtype 64 65
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

    # 配置 MosDNS 核心平滑升级脚本 (/usr/local/bin/update_mosdns.sh 与 /usr/local/bin/update-mosdns)
    info "配置 MosDNS 核心平滑升级脚本 (/usr/local/bin/update-mosdns)..."
    cat > /usr/local/bin/update_mosdns.sh << 'EOF'
#!/usr/bin/env bash
# ==============================================================================
# Script: update-mosdns (update_mosdns.sh)
# Description: MosDNS 核心全自动从 GitHub Releases 获取最新二进制并安全平滑升级
# Project: singbox-mosdns-daed-router
# ==============================================================================

set -eo pipefail

echo "🔍 正在检查 MosDNS 最新版本..."

# 1. 通过 GitHub 网页 302 重定向获取真实最新 Tag（无需 API，不限流，稳定可靠）
LATEST_URL=$(curl -sIL -o /dev/null -w '%{url_effective}' --connect-timeout 10 https://github.com/IrineSistiana/mosdns/releases/latest 2>/dev/null || true)
if [[ -z "$LATEST_URL" || "$LATEST_URL" == *"releases/latest"* ]]; then
    LATEST_URL=$(curl -sIL -x socks5h://127.0.0.1:7891 -o /dev/null -w '%{url_effective}' --connect-timeout 10 https://github.com/IrineSistiana/mosdns/releases/latest 2>/dev/null || true)
fi

LATEST_TAG=$(basename "${LATEST_URL}")

if [[ ! "$LATEST_TAG" =~ ^v[0-9] ]]; then
    echo "❌ 获取最新版本失败（获取到: ${LATEST_TAG}），请检查网络连接。"
    exit 1
fi

VERSION=${LATEST_TAG#v}

# 2. 检查当前已安装版本
CURRENT_VER=$(mosdns version 2>/dev/null | awk '{print $2}' || mosdns version 2>/dev/null | head -n 1 || echo "未安装")
echo "📌 当前已安装版本: ${CURRENT_VER}"
echo "🚀 官方最新发布版本: ${LATEST_TAG}"

if [[ "$CURRENT_VER" == "$VERSION" || "$CURRENT_VER" == "$LATEST_TAG" ]]; then
    if [[ "$1" != "-f" && "$1" != "--force" ]]; then
        echo "✨ 当前 MosDNS 已是最新版本 (${CURRENT_VER})，无需重复更新。(强制重新下载请加参数: -f)"
        exit 0
    fi
fi

# 3. 判断系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64)   MOS_ARCH="amd64" ;;
    aarch64|arm64)  MOS_ARCH="arm64" ;;
    *) echo "❌ 未知架构: $ARCH"; exit 1 ;;
esac

ZIP_NAME="mosdns-linux-${MOS_ARCH}.zip"
RAW_URL="https://github.com/IrineSistiana/mosdns/releases/download/${LATEST_TAG}/${ZIP_NAME}"
PROXY_URL="https://gh-proxy.com/${RAW_URL}"
FALLBACK_URL="https://ghfast.top/${RAW_URL}"

echo "📦 准备下载软件包: ${ZIP_NAME} ..."

TMP_DIR=$(mktemp -d)

# 4. 多通道容灾下载（优先加速镜像，其次本地代理，最后直连）
download_success=false
if curl -f -L --connect-timeout 15 -o "${TMP_DIR}/${ZIP_NAME}" "${PROXY_URL}" 2>/dev/null; then
    echo "✅ 通过 gh-proxy 镜像站下载成功。"
    download_success=true
elif curl -f -L -x socks5h://127.0.0.1:7891 --connect-timeout 15 -o "${TMP_DIR}/${ZIP_NAME}" "${RAW_URL}" 2>/dev/null; then
    echo "✅ 通过本地代理通道下载成功。"
    download_success=true
elif curl -f -L --connect-timeout 15 -o "${TMP_DIR}/${ZIP_NAME}" "${FALLBACK_URL}" 2>/dev/null; then
    echo "✅ 通过 ghfast 镜像站下载成功。"
    download_success=true
elif curl -f -L --connect-timeout 15 -o "${TMP_DIR}/${ZIP_NAME}" "${RAW_URL}" 2>/dev/null; then
    echo "✅ 通过直连 GitHub 下载成功。"
    download_success=true
fi

if [[ "$download_success" != true || ! -s "${TMP_DIR}/${ZIP_NAME}" ]]; then
    echo "❌ 下载 MosDNS 失败，请检查网络连接！"
    rm -rf "${TMP_DIR}"
    exit 1
fi

echo "📦 正在解压并更新二进制文件..."
unzip -q -o "${TMP_DIR}/${ZIP_NAME}" -d "${TMP_DIR}/extracted"

NEW_BIN="${TMP_DIR}/extracted/mosdns"
if [[ ! -f "$NEW_BIN" ]]; then
    echo "❌ 解压后未找到有效 mosdns 二进制文件！"
    rm -rf "${TMP_DIR}"
    exit 1
fi
chmod +x "$NEW_BIN"

if ! "$NEW_BIN" version >/dev/null 2>&1; then
    echo "❌ 新版 mosdns 在当前系统无法正常执行！已终止替换。"
    rm -rf "${TMP_DIR}"
    exit 1
fi

if [[ -f /usr/local/bin/mosdns ]]; then
    cp -pf /usr/local/bin/mosdns /usr/local/bin/mosdns.bak 2>/dev/null || true
fi

systemctl stop mosdns 2>/dev/null || true
cp -f "$NEW_BIN" /usr/local/bin/mosdns
chmod +x /usr/local/bin/mosdns
rm -rf "${TMP_DIR}"

if systemctl restart mosdns && systemctl is-active --quiet mosdns; then
    echo "🎉 MosDNS 已成功更新至 ${LATEST_TAG} 并重启服务！"
    /usr/local/bin/mosdns version
else
    echo "❌ 服务启动失败，正在回滚旧版程序..."
    if [[ -f /usr/local/bin/mosdns.bak ]]; then
        cp -pf /usr/local/bin/mosdns.bak /usr/local/bin/mosdns
        systemctl restart mosdns || true
        echo "⚠️ 已回滚至旧版本。"
    fi
    exit 1
fi
EOF
    chmod +x /usr/local/bin/update_mosdns.sh
    ln -sf /usr/local/bin/update_mosdns.sh /usr/local/bin/update-mosdns

    success "MosDNS 服务与升级脚本 (/usr/local/bin/update-mosdns) 已就绪！"
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

    # 配置 Sing-box 核心平滑升级脚本 (/usr/local/bin/update_singbox.sh 与 /usr/local/bin/update-sing-box)
    info "配置 Sing-box 核心平滑升级脚本 (/usr/local/bin/update-sing-box)..."
    cat > /usr/local/bin/update_singbox.sh << 'EOF'
#!/usr/bin/env bash
# ==============================================================================
# Script: update-sing-box (update_singbox.sh)
# Description: sing-box 核心全自动从 GitHub Releases 获取最新二进制并安全平滑升级
# Project: singbox-mosdns-daed-router
# ==============================================================================

set -eo pipefail

echo "🔍 正在检查 sing-box 最新版本..."

# 1. 通过 GitHub 网页 302 重定向获取真实最新 Tag（无需 API，不限流，稳定可靠）
LATEST_URL=$(curl -sIL -o /dev/null -w '%{url_effective}' --connect-timeout 10 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null || true)
if [[ -z "$LATEST_URL" || "$LATEST_URL" == *"releases/latest"* ]]; then
    LATEST_URL=$(curl -sIL -x socks5h://127.0.0.1:7891 -o /dev/null -w '%{url_effective}' --connect-timeout 10 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null || true)
fi

LATEST_TAG=$(basename "${LATEST_URL}")

if [[ ! "$LATEST_TAG" =~ ^v[0-9] ]]; then
    echo "❌ 获取最新版本失败（获取到: ${LATEST_TAG}），请检查网络连接。"
    exit 1
fi

VERSION=${LATEST_TAG#v}

# 2. 检查当前已安装版本
CURRENT_VER=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}' || echo "未安装")
echo "📌 当前已安装版本: ${CURRENT_VER}"
echo "🚀 官方最新发布版本: ${LATEST_TAG}"

if [[ "$CURRENT_VER" == "$VERSION" || "$CURRENT_VER" == "$LATEST_TAG" ]]; then
    if [[ "$1" != "-f" && "$1" != "--force" ]]; then
        echo "✨ 当前 sing-box 已是最新版本 (${CURRENT_VER})，无需重复更新。(强制重新下载请加参数: -f)"
        exit 0
    fi
fi

# 3. 判断系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64)   SB_ARCH="amd64" ;;
    aarch64|arm64)  SB_ARCH="arm64" ;;
    armv7l)         SB_ARCH="armv7" ;;
    *) echo "❌ 未知架构: $ARCH"; exit 1 ;;
esac

RAW_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
PROXY_URL="https://gh-proxy.com/${RAW_URL}"
FALLBACK_URL="https://ghfast.top/${RAW_URL}"

echo "📦 准备下载软件包: sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz ..."

TMP_DIR=$(mktemp -d)

# 4. 多通道容灾下载（优先加速镜像，其次本地代理，最后直连）
download_success=false
if curl -f -L --connect-timeout 15 -o "${TMP_DIR}/sing-box.tar.gz" "${PROXY_URL}" 2>/dev/null; then
    echo "✅ 通过 gh-proxy 镜像站下载成功。"
    download_success=true
elif curl -f -L -x socks5h://127.0.0.1:7891 --connect-timeout 15 -o "${TMP_DIR}/sing-box.tar.gz" "${RAW_URL}" 2>/dev/null; then
    echo "✅ 通过本地代理通道下载成功。"
    download_success=true
elif curl -f -L --connect-timeout 15 -o "${TMP_DIR}/sing-box.tar.gz" "${FALLBACK_URL}" 2>/dev/null; then
    echo "✅ 通过 ghfast 镜像站下载成功。"
    download_success=true
elif curl -f -L --connect-timeout 15 -o "${TMP_DIR}/sing-box.tar.gz" "${RAW_URL}" 2>/dev/null; then
    echo "✅ 通过直连 GitHub 下载成功。"
    download_success=true
fi

if [[ "$download_success" != true || ! -s "${TMP_DIR}/sing-box.tar.gz" ]]; then
    echo "❌ 下载 sing-box 失败，请检查网络连接！"
    rm -rf "${TMP_DIR}"
    exit 1
fi

echo "📦 正在解压并更新二进制文件..."
tar -xzf "${TMP_DIR}/sing-box.tar.gz" -C "${TMP_DIR}"

NEW_BIN=$(find "${TMP_DIR}" -type f -name "sing-box" | head -n 1)
if [[ -z "$NEW_BIN" || ! -f "$NEW_BIN" ]]; then
    echo "❌ 解压后未找到有效 sing-box 二进制文件！"
    rm -rf "${TMP_DIR}"
    exit 1
fi
chmod +x "$NEW_BIN"

CONFIG_FILE="/etc/sing-box/config.json"
if [[ -f "$CONFIG_FILE" ]]; then
    echo "🔍 正在使用新版核心预检配置文件语法..."
    if ! "$NEW_BIN" check -c "$CONFIG_FILE"; then
        echo "❌ 新版本核心对当前配置文件校验失败！已终止替换，保持现有服务正常运行。"
        rm -rf "${TMP_DIR}"
        exit 1
    fi
    echo "✅ 配置文件校验通过。"
fi

if [[ -f /usr/local/bin/sing-box ]]; then
    cp -pf /usr/local/bin/sing-box /usr/local/bin/sing-box.bak 2>/dev/null || true
fi

systemctl stop sing-box 2>/dev/null || true
cp -f "$NEW_BIN" /usr/local/bin/sing-box
chmod +x /usr/local/bin/sing-box

if [[ -f /usr/bin/sing-box || -L /usr/bin/sing-box ]]; then
    cp -pf /usr/local/bin/sing-box /usr/bin/sing-box
fi

rm -rf "${TMP_DIR}"

if systemctl restart sing-box && systemctl is-active --quiet sing-box; then
    echo "🎉 sing-box 已成功更新至 ${LATEST_TAG} 并重启服务！"
    /usr/local/bin/sing-box version
else
    echo "❌ 服务启动失败，正在回滚旧版程序..."
    if [[ -f /usr/local/bin/sing-box.bak ]]; then
        cp -pf /usr/local/bin/sing-box.bak /usr/local/bin/sing-box
        [[ -f /usr/bin/sing-box ]] && cp -pf /usr/local/bin/sing-box.bak /usr/bin/sing-box
        systemctl restart sing-box || true
        echo "⚠️ 已回滚至旧版本。"
    fi
    exit 1
fi
EOF
    chmod +x /usr/local/bin/update_singbox.sh
    ln -sf /usr/local/bin/update_singbox.sh /usr/local/bin/update-sing-box

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
    echo -e "  - ⚡ 升级 Sing-box 核心 : ${YELLOW}sudo /usr/local/bin/update-sing-box${PLAIN} (或 update_singbox.sh)"
    echo -e "  - 🌐 升级 MosDNS 核心   : ${YELLOW}sudo /usr/local/bin/update-mosdns${PLAIN} (或 update_mosdns.sh)"
    echo -e "  - 📊 升级 Web 仪表板    : ${YELLOW}sudo /usr/local/bin/update_metacubexd.sh${PLAIN}"
    echo -e "  - 📋 升级 DNS 规则库    : ${YELLOW}sudo /etc/mosdns/mos_rule_update.sh${PLAIN}"
    echo ""
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}【关于翻墙节点配置】:${PLAIN}"
    echo -e "  - 旁路由基础服务现已就绪，当前 Sing-box 处于安全直连（保底）模式。"
    echo -e "  - 💡 ${YELLOW}还没有自建节点？${PLAIN} 推荐使用配套服务端脚本部署 VPS: ${BLUE}https://github.com/luckyjamesriver/vps-sing-box${PLAIN}"
    echo -e "  - 🔑 ${YELLOW}已有自建节点？${PLAIN} 请将您的节点信息填入 ${CYAN}/etc/sing-box/config.json${PLAIN} 并执行: ${GREEN}systemctl restart sing-box${PLAIN}"
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
