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
    # 若直连失败，尝试通过本地代理获取
    LATEST_URL=$(curl -sIL -x socks5h://127.0.0.1:7891 -o /dev/null -w '%{url_effective}' --connect-timeout 10 https://github.com/IrineSistiana/mosdns/releases/latest 2>/dev/null || true)
fi

LATEST_TAG=$(basename "${LATEST_URL}")

# 校验提取到的 Tag 格式（必须以 v 开头）
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

# 5. 自检：确保当前指令集与 glibc 可正常执行
if ! "$NEW_BIN" version >/dev/null 2>&1; then
    echo "❌ 新版 mosdns 在当前系统无法正常执行！已终止替换。"
    rm -rf "${TMP_DIR}"
    exit 1
fi

# 6. 备份现有程序
if [[ -f /usr/local/bin/mosdns ]]; then
    cp -pf /usr/local/bin/mosdns /usr/local/bin/mosdns.bak 2>/dev/null || true
fi

# 7. 部署新二进制
systemctl stop mosdns 2>/dev/null || true
cp -f "$NEW_BIN" /usr/local/bin/mosdns
chmod +x /usr/local/bin/mosdns
rm -rf "${TMP_DIR}"

# 8. 恢复并验证服务
systemctl restart mosdns
sleep 1

if systemctl is-active --quiet mosdns; then
    echo "🎉 MosDNS 已成功更新至 ${LATEST_TAG} 并重启服务！"
    /usr/local/bin/mosdns version
else
    echo "❌ 服务启动失败，正在回滚旧版程序..."
    if [[ -f /usr/local/bin/mosdns.bak ]]; then
        cp -pf /usr/local/bin/mosdns.bak /usr/local/bin/mosdns
        systemctl restart mosdns
        echo "⚠️ 已回滚至旧版本。"
    fi
    exit 1
fi
