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
    # 优先尝试本地代理，次选直连，最后镜像
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

# 运行自测：确保新二进制能够在当前内核与 glibc 下正常执行
if ! "$NEW_BIN" version >/dev/null 2>&1; then
    log_error "新版本 mosdns 二进制在当前系统无法正常执行 (可能指令集或 glibc 不匹配)！已中止升级。"
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
