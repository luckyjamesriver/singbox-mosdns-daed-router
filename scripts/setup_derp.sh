#!/usr/bin/env bash
# ==============================================================================
# Project: singbox-mosdns-daed-router
# Script: setup_derp.sh (Tailscale DERP + 子网路由 + 出口节点一键安装脚本)
# Description: 自动化构建私有 DERP 中继服务器，并配置全能 Subnet Router 与 Exit Node
# Repository: https://github.com/luckyjamesriver/singbox-mosdns-daed-router
# License: MIT
# ==============================================================================

set -e

# --- 颜色常量 ---
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

# --- 检查 Root 权限与系统 ---
check_environment() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 用户运行！请执行: sudo -i 或 sudo bash $0"
        exit 1
    fi

    if [[ ! -f /etc/os-release ]]; then
        error "无法识别操作系统，推荐在 Debian 12 (Bookworm) 或 Ubuntu 22.04+ 上运行！"
        exit 1
    fi

    source /etc/os-release
    info "检测到操作系统: ${PRETTY_NAME}"
}

# --- 交互式参数收集 ---
collect_parameters() {
    title "1. 配置 DERP 基础参数"
    
    echo -e "说明: 因家庭宽带 80/443 端口通常被运营商阻断，DERP 推荐使用高位端口（如 33445）。"
    echo -e "      同时请确保在主路由（RouterOS / 爱快等）上已完成相应端口的公网 NAT 映射。\n"

    read -rp "请输入 DERP 绑定的域名 (例如: derp.example.com): " DERP_DOMAIN
    while [[ -z "${DERP_DOMAIN}" ]]; do
        warn "域名不能为空！"
        read -rp "请输入 DERP 绑定的域名: " DERP_DOMAIN
    done

    read -rp "请输入 DERP HTTPS 监听端口 [默认 33445]: " DERP_PORT
    DERP_PORT=${DERP_PORT:-33445}

    read -rp "请输入 STUN 探测 UDP 端口 [默认 3478]: " STUN_PORT
    STUN_PORT=${STUN_PORT:-3478}

    read -rp "请输入要宣告的家庭局域网子网网段 [默认 10.10.11.0/24]: " SUBNET_ROUTE
    SUBNET_ROUTE=${SUBNET_ROUTE:-"10.10.11.0/24"}

    read -rp "请输入 Tailscale 节点名称 [默认 home-derp]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-"home-derp"}

    echo ""
    info "配置确认:"
    echo "  - 绑定域名: ${DERP_DOMAIN}"
    echo "  - DERP 端口: ${DERP_PORT} (TCP)"
    echo "  - STUN 端口: ${STUN_PORT} (UDP)"
    echo "  - 子网路由: ${SUBNET_ROUTE}"
    echo "  - 节点名称: ${NODE_NAME}"
    echo ""
    read -rp "确认无误并开始安装？[Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-"y"}
    if [[ "${CONFIRM}" =~ ^[Nn]$ ]]; then
        warn "已取消安装。"
        exit 0
    fi
}

# --- 安装系统核心依赖 ---
install_dependencies() {
    title "2. 安装系统依赖与基础组件"
    apt-get update
    apt-get install -y curl wget git iptables nftables cron openssl procps ufw- || true
    apt-get install -y curl wget git iptables cron openssl procps ethtool
    success "基础依赖安装完成。"
}

# --- 安装并编译 derper ---
install_derper() {
    title "3. 安装与编译 derper 服务端"

    mkdir -p /etc/derp

    if command -v /usr/local/bin/derper >/dev/null 2>&1; then
        info "检测到已存在 /usr/local/bin/derper，跳过重新编译。"
        return 0
    fi

    # 检查 Go 环境
    if ! command -v go >/dev/null 2>&1; then
        info "未检测到 Go 环境，正在安装最新版 Go..."
        GO_VERSION="1.22.6"
        ARCH=$(uname -m)
        case "${ARCH}" in
            x86_64)  GO_ARCH="amd64" ;;
            aarch64) GO_ARCH="arm64" ;;
            *) error "暂不支持的 CPU 架构: ${ARCH}"; exit 1 ;;
        esac

        wget -q --show-progress "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -O /tmp/go.tar.gz
        rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz
        rm -f /tmp/go.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    fi

    info "使用 Go 编译安装 tailscale.com/cmd/derper@latest ..."
    export GOPATH=/root/go
    /usr/local/go/bin/go install tailscale.com/cmd/derper@latest

    if [[ -f /root/go/bin/derper ]]; then
        cp -f /root/go/bin/derper /usr/local/bin/derper
        chmod +x /usr/local/bin/derper
        success "derper 编译完成并安装至 /usr/local/bin/derper"
    else
        error "derper 编译失败，请检查网络或 Go 环境！"
        exit 1
    fi
}

# --- 初始化 SSL 证书占位 ---
setup_ssl_placeholder() {
    title "4. 初始化 SSL 证书配置"
    CERT_FILE="/etc/derp/${DERP_DOMAIN}.crt"
    KEY_FILE="/etc/derp/${DERP_DOMAIN}.key"

    if [[ -f "${CERT_FILE}" && -f "${KEY_FILE}" ]]; then
        info "已存在证书文件: ${CERT_FILE}，保留现有证书。"
    else
        warn "未检测到现有 SSL 证书，正在生成用于启动的临时自签名证书..."
        openssl req -x509 -nodes -days 365 -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "${KEY_FILE}" \
            -out "${CERT_FILE}" \
            -subj "/CN=${DERP_DOMAIN}"
        chmod 600 "${KEY_FILE}"
        tip "提示: 后续请使用 acme.sh 申请受信任的正式 CA 证书（如 Let's Encrypt / ZeroSSL）并覆盖或软链接至此。"
    fi
}

# --- 配置 derp Systemd 服务 ---
setup_derper_service() {
    title "5. 配置 derp 系统服务"

    cat << EOF > /etc/systemd/system/derp.service
[Unit]
Description=Tailscale Private DERP Server
After=network.target tailscaled.service
Wants=network.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5
StartLimitInterval=0
LimitNOFILE=65536
ExecStart=/usr/local/bin/derper -a :${DERP_PORT} -http-port -1 -stun -stun-port ${STUN_PORT} -hostname ${DERP_DOMAIN} -certmode manual -certdir /etc/derp -verify-clients

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable derp
    systemctl restart derp
    success "derp.service 服务已配置并启动。"
}

# --- 安装并配置 Tailscale ---
setup_tailscale() {
    title "6. 安装 Tailscale 客户端"

    if ! command -v tailscale >/dev/null 2>&1; then
        info "正在安装 Tailscale 官方软件包..."
        curl -fsSL https://tailscale.com/install.sh | sh
    else
        info "Tailscale 已安装: $(tailscale version | head -n 1)"
    fi

    systemctl enable tailscaled --now
}

# --- 内核网络与路由转发调优 ---
optimize_kernel_and_nat() {
    title "7. 系统内核路由转发与 TCP MSS 调优"

    cat << 'EOF' > /etc/sysctl.d/99-tailscale-derp.conf
# 开启 IPv4 与 IPv6 内核数据转发 (Subnet Router 与 Exit Node 必需)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# 关闭反向路径过滤 (Overlay 虚拟网卡多宿主互联必需)
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# 禁用 ICMP 重定向发送 (路由器不向内网客户端发 redirect)
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# TCP BBR 拥塞控制与低延迟 FQ 排队
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# NAT 连接跟踪上限调优
net.netfilter.nf_conntrack_max = 262144

# 增大 UDP 套接字缓冲区 (优化 WireGuard 与 DERP 吞吐)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
EOF

    sysctl -p /etc/sysctl.d/99-tailscale-derp.conf

    # TCP MSS Clamping 优化 (防止 Tailscale 1280 MTU 分片卡死)
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    # 持久化到 /etc/network/interfaces (若使用 Debian 标准网络管理)
    if [[ -f /etc/network/interfaces ]] && ! grep -q "TCPMSS --clamp-mss-to-pmtu" /etc/network/interfaces; then
        cat << 'EOF' >> /etc/network/interfaces
  # TCP MSS Clamping (防止 Tailscale MTU 1280 导致大包分片卡顿)
  post-up iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  post-up ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF
    fi

    success "内核路由转发与 TCP MSS 调优已完成并持久化。"
}

# --- 启动 Tailscale 宣告 ---
start_tailscale_routing() {
    title "8. 启动 Tailscale 节点并宣告子网路由与出口节点"

    info "正在启动 Tailscale 并宣告路由..."
    echo -e "  - 子网路由: ${SUBNET_ROUTE}"
    echo -e "  - 全局出口: 0.0.0.0/0, ::/0"
    echo -e "  - 节点名称: ${NODE_NAME}\n"

    # 执行 tailscale up
    tailscale up \
        --advertise-routes="${SUBNET_ROUTE},0.0.0.0/0,::/0" \
        --hostname="${NODE_NAME}" \
        --reset || true
}

# --- 输出完成向导 ---
print_completion_guide() {
    title "🎉 部署完成！后续配置向导"

    echo -e "${CYAN}一、 主路由端口映射 (NAT Port Forwarding)${PLAIN}"
    echo -e "请在 RouterOS / 爱快等主路由上配置外网端口转发（将外网流量引导至本 DERP 节点）："
    echo -e "  ${GREEN}1. TCP 端口${PLAIN}: 外部 ${DERP_PORT} -> 本机内网IP:${DERP_PORT} (DERP 流量通道)"
    echo -e "  ${GREEN}2. UDP 端口${PLAIN}: 外部 ${STUN_PORT} -> 本机内网IP:${STUN_PORT} (STUN 连通性探测)"
    echo ""
    echo -e "${CYAN}二、 Tailscale 控制台审批 (Machines 页面)${PLAIN}"
    echo -e "请打开官方控制台: ${BLUE}https://console.tailscale.com/admin/machines${PLAIN}"
    echo -e "  1. 找到本节点 [${NODE_NAME}]，点击右侧操作菜单 (···) -> ${YELLOW}Edit route settings${PLAIN}。"
    echo -e "  2. 勾选批准 Subnet routes (${SUBNET_ROUTE})。"
    echo -e "  3. 勾选批准 Exit node (0.0.0.0/0, ::/0)。"
    echo -e "  4. 推荐点击 (···) -> ${YELLOW}Disable key expiry${PLAIN}，防止服务器节点定期密钥过期。"
    echo ""
    echo -e "${CYAN}三、 Tailscale 接入自定义 DERP (ACLs 页面)${PLAIN}"
    echo -e "请打开官方控制台: ${BLUE}https://console.tailscale.com/admin/acls${PLAIN}"
    echo -e "在 ACL JSON 配置中加入以下 derpMap 规则（RegionID 可自定义为 900+ 专属区域）："
    echo -e "${PURPLE}------------------------------------------------------------${PLAIN}"
    cat << EOF
"derpMap": {
  "OmitDefaultRegions": false,
  "Regions": {
    "900": {
      "RegionID": 900,
      "RegionCode": "HomeDERP",
      "RegionName": "Home Private Relay",
      "Nodes": [
        {
          "Name": "${NODE_NAME}",
          "RegionID": 900,
          "HostName": "${DERP_DOMAIN}",
          "DERPPort": ${DERP_PORT},
          "STUNPort": ${STUN_PORT},
          "InsecureForTests": false
        }
      ]
    }
  }
}
EOF
    echo -e "${PURPLE}------------------------------------------------------------${PLAIN}"
    echo -e "${CYAN}四、 常用运维命令${PLAIN}"
    echo -e "  - 查看 DERP 服务状态: ${GREEN}systemctl status derp${PLAIN}"
    echo -e "  - 查看 Tailscale 状态: ${GREEN}tailscale status${PLAIN}"
    echo -e "  - 测试当前 DERP 延迟: ${GREEN}tailscale netcheck${PLAIN}"
    echo -e "  - 查看本节点出海分流: ${GREEN}curl -s https://api.ipify.org${PLAIN}"
    echo ""
}

main() {
    check_environment
    collect_parameters
    install_dependencies
    install_derper
    setup_ssl_placeholder
    setup_derper_service
    setup_tailscale
    optimize_kernel_and_nat
    start_tailscale_routing
    print_completion_guide
}

main "$@"
