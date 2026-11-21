#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: sync_pve_backups.sh
# 用途: 一键从 PVE (10.10.11.2) 拉取虚拟机 100, 201, 202, 401 的最新备份文件至本地当前目录
# 特性: 
#   1. 自动寻找每个 VM 的最新备份（含 .vma.zst, .log, .notes）
#   2. 使用 rsync 支持断点续传、实时传输速度与进度显示
#   3. 已下载的文件自动跳过，秒级校验
# ==============================================================================

set -eo pipefail

PVE_HOST="${PVE_HOST:-10.10.11.2}"
PVE_USER="root"
PVE_DUMP_DIR="/var/lib/vz/dump"
TARGET_VMS=(100 201 202 401)

# 本地保存目录为当前脚本所在目录
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 终端高亮配色
GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
NC="\033[0m"

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}        PVE (10.10.11.2) 虚拟机最新备份一键同步工具              ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "目标主机 : ${YELLOW}${PVE_USER}@${PVE_HOST}${NC}"
echo -e "备份源路径: ${YELLOW}${PVE_DUMP_DIR}${NC}"
echo -e "本地存储 : ${YELLOW}${LOCAL_DIR}${NC}"
echo -e "目标虚拟机: ${BLUE}${TARGET_VMS[*]}${NC}"
echo -e "----------------------------------------------------------------"

# 1. 检查 SSH 免密连接
echo -e "🔍 正在检查与 PVE (${PVE_HOST}) 的 SSH 连接..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${PVE_USER}@${PVE_HOST}" "true" 2>/dev/null; then
    echo -e "${RED}❌ 错误: 无法免密连接到 ${PVE_USER}@${PVE_HOST}，请先配置 SSH Key 登录！${NC}"
    exit 1
fi
echo -e "${GREEN}✓ SSH 连接正常！${NC}\n"

# 2. 依次同步各个虚拟机的最新备份
for vmid in "${TARGET_VMS[@]}"; do
    echo -e "${BLUE}================================================================${NC}"
    echo -e "📦 正在查询 VM [${YELLOW}${vmid}${NC}] 的最新备份..."

    # 在 PVE 上寻找该 VMID 修改时间最新的主备份文件 (支持 qemu/lxc, vma.zst/tar.zst)
    LATEST_ARCHIVE=$(ssh "${PVE_USER}@${PVE_HOST}" "ls -t ${PVE_DUMP_DIR}/vzdump-*-${vmid}-*.* 2>/dev/null | grep -E '\.(vma|tar)(\.(zst|gz|lzo))?$' | head -n 1" || true)

    if [[ -z "${LATEST_ARCHIVE}" ]]; then
        echo -e "${RED}⚠️  警告: 在 ${PVE_DUMP_DIR} 下未找到 VM [${vmid}] 的有效备份文件，跳过。${NC}"
        continue
    fi

    BASE_PREFIX="${LATEST_ARCHIVE%.vma*}"
    BASE_PREFIX="${BASE_PREFIX%.tar*}"

    FILE_NAME=$(basename "${LATEST_ARCHIVE}")
    FILE_SIZE=$(ssh "${PVE_USER}@${PVE_HOST}" "ls -lh '${LATEST_ARCHIVE}' | awk '{print \$5}'")
    
    echo -e "  - 命中最新备份: ${GREEN}${FILE_NAME}${NC} (大小: ${CYAN}${FILE_SIZE}${NC})"
    echo -e "  - 正在使用 rsync 传输 (支持断点续传)..."

    # 拉取主备份文件以及伴随的 .log、.notes 文件
    rsync -avP --partial \
        "${PVE_USER}@${PVE_HOST}:${BASE_PREFIX}*" \
        "${LOCAL_DIR}/"

    echo -e "${GREEN}✓ VM [${vmid}] 同步完成！${NC}\n"
done

echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}🎉 所有指定虚拟机的最新备份已全部成功同步至本地！${NC}"
echo -e "本地文件列表:"
ls -lh "${LOCAL_DIR}"
echo -e "${CYAN}================================================================${NC}"
