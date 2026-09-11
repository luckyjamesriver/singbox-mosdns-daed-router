#!/usr/bin/env bash
# ==============================================================================
# Project: A-side-router-on-Debian-12
# Script: setup.sh (Debian 12 旁路由核心服务一键全自动部署脚本)
# Description: 全自动完成 MosDNS v5 + Sing-box 1.14+ + MetaCubeXD + daed eBPF 安装调优
# Repository: https://github.com/luckyjamesriver/A-side-router-on-Debian-12
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
    echo -e "${BLUE}  GitHub: https://github.com/luckyjamesriver/A-side-router-on-Debian-12${PLAIN}"
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
    touch /etc/mosdns/rules/ai-proxy.txt

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
    info "生成 MosDNS 标准分流配置 (/etc/mosdns/config.yaml)..."
    cat > /etc/mosdns/config.yaml << EOF
log:
  level: info
  file: ""

plugins:
  # 1. 规则匹配插件
  - tag: geosite_cn
    type: domain_set
    args:
      files:
        - "/etc/mosdns/rules/geosite_cn.txt"
        - "/etc/mosdns/rules/force-cn.txt"

  - tag: geosite_apple
    type: domain_set
    args:
      files:
        - "/etc/mosdns/rules/geosite_apple.txt"

  - tag: geosite_no_cn
    type: domain_set
    args:
      files:
        - "/etc/mosdns/rules/geosite_geolocation-!cn.txt"
        - "/etc/mosdns/rules/ai-proxy.txt"

  - tag: geoip_cn
    type: ip_set
    args:
      files:
        - "/etc/mosdns/rules/geoip_cn.txt"

  # 2. 上游 DNS 服务器插件
  - tag: forward_local
    type: forward
    args:
      concurrent: 3
      upstreams:
        - addr: "${GATEWAY_IP}"
        - addr: "223.5.5.5"
        - addr: "119.29.29.29"

  - tag: forward_remote
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "tls://1.1.1.1"
          enable_pipeline: true
        - addr: "tls://8.8.8.8"
          enable_pipeline: true

  # 3. 内存缓存插件
  - tag: cache
    type: cache
    args:
      size: 20000
      lazy_cache_ttl: 86400

  # 4. 主要执行逻辑流
  - tag: main_sequence
    type: sequence
    args:
      - exec: \$cache
      - matches: has_resp
        exec: accept

      - matches: qtype 65
        exec: reject 3

      - matches: qname \$geosite_apple
        exec: \$forward_local
      - matches: has_resp
        exec: accept

      - matches: qname \$geosite_cn
        exec: \$forward_local
      - matches: has_resp
        exec: accept

      - matches: qname \$geosite_no_cn
        exec: \$forward_remote
      - matches: has_resp
        exec: accept

      - exec: \$forward_local
      - matches: response_ip \$geoip_cn
        exec: accept

      - exec: drop_resp
      - exec: \$forward_remote

  # 5. 监听端口 (TCP & UDP 53)
  - tag: udp_server
    type: udp_server
    args:
      entry: main_sequence
      listen: "0.0.0.0:53"

  - tag: tcp_server
    type: tcp_server
    args:
      entry: main_sequence
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
    success "MosDNS 服务已部署并成功运行在 0.0.0.0:53！"
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
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}【接下来您只需完成两步】:${PLAIN}"
    echo -e "  ${GREEN}第一步：浏览器打开 daed 网页管理面板${PLAIN}"
    echo -e "    1. 访问: ${YELLOW}http://${LOCAL_IP}:2023${PLAIN} (初次打开设置管理员账号密码)"
    echo -e "    2. 在【接口】中选择: ${GREEN}${INTERFACE}${PLAIN}"
    echo -e "    3. 添加您的订阅节点，或将本地 Sing-box (socks5://127.0.0.1:7891) 作为出站"
    echo -e "    4. 点击右上角运行按钮启动 eBPF 内核级透明分流！"
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
