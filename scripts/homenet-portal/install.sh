#!/usr/bin/env bash
# ==============================================================================
# Script: install.sh (HomeNet Portal 2.0 一键安装与配置脚本)
# Description: 纯原生部署零开销 Homepage 风格网络监控导航门户
# ==============================================================================

set -e

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[1;36m"
PLAIN="\033[0m"

echo -e "${CYAN}🚀 开始部署 / 更新 HomeNet Portal 2.0 监控仪表盘...${PLAIN}"

TARGET_DIR="/opt/homenet-portal"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "${TARGET_DIR}/static"

# 1. 复制核心程序
cp -f "${SCRIPT_DIR}/server.py" "${TARGET_DIR}/server.py"
chmod +x "${TARGET_DIR}/server.py"
cp -f "${SCRIPT_DIR}/static/index.html" "${TARGET_DIR}/static/index.html"

# 2. 如果配置文件不存在，则从示例配置初始化
if [[ ! -f "${TARGET_DIR}/config.json" ]]; then
    if [[ -f "${SCRIPT_DIR}/config.example.json" ]]; then
        cp -f "${SCRIPT_DIR}/config.example.json" "${TARGET_DIR}/config.json"
        echo -e "${GREEN}[INFO]${PLAIN} 已生成默认配置文件: ${TARGET_DIR}/config.json"
    fi
else
    echo -e "${YELLOW}[INFO]${PLAIN} 保留现有配置文件: ${TARGET_DIR}/config.json"
fi

# 3. 配置 Systemd 服务
cp -f "${SCRIPT_DIR}/homenet-portal.service" "/etc/systemd/system/homenet-portal.service"
systemctl daemon-reload
systemctl enable homenet-portal --now
systemctl restart homenet-portal

LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -n 1 || hostname -I | awk '{print $1}')

echo -e "${GREEN}====================================================${PLAIN}"
echo -e "${GREEN}  🎉 HomeNet Portal 2.0 已成功启动！${PLAIN}"
echo -e "${GREEN}====================================================${PLAIN}"
echo -e "  - 🌐 访问地址 : ${YELLOW}http://${LOCAL_IP}:8888${PLAIN}"
echo -e "  - 📁 安装目录 : ${CYAN}${TARGET_DIR}${PLAIN}"
echo -e "  - ⚙️  配置文件 : ${CYAN}${TARGET_DIR}/config.json${PLAIN}"
echo -e "  - 🔄 服务状态 : ${GREEN}systemctl status homenet-portal${PLAIN}"
echo ""
