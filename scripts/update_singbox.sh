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
    # 若直连失败，尝试通过本地代理获取
    LATEST_URL=$(curl -sIL -x socks5h://127.0.0.1:7891 -o /dev/null -w '%{url_effective}' --connect-timeout 10 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null || true)
fi

LATEST_TAG=$(basename "${LATEST_URL}")

# 校验提取到的 Tag 格式（必须以 v 开头）
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

# 4. 多通道容灾下载（优先加速镜像，其次本地代理通道，最后直连）
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

# 5. 安全预检：新核心校验现有配置文件
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

# 6. 备份现有旧程序
if [[ -f /usr/local/bin/sing-box ]]; then
    cp -pf /usr/local/bin/sing-box /usr/local/bin/sing-box.bak 2>/dev/null || true
fi

# 7. 部署新二进制 (同时覆盖 /usr/local/bin 与 /usr/bin，保证服务与命令行一致生效)
systemctl stop sing-box 2>/dev/null || true
cp -f "$NEW_BIN" /usr/local/bin/sing-box
chmod +x /usr/local/bin/sing-box

if [[ -f /usr/bin/sing-box || -L /usr/bin/sing-box ]]; then
    cp -pf /usr/local/bin/sing-box /usr/bin/sing-box
fi

rm -rf "${TMP_DIR}"

# 8. 恢复并验证服务 (将 restart 纳入条件判断，防止 set -e 在重启失败时直接退出导致无法回滚)
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
