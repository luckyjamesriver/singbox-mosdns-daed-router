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
