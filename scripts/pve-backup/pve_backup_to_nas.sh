#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: pve_backup_to_nas.sh
# 运行环境: PVE 主机 (10.10.11.2) - 7x24 小时开机独立运行
# 用途: 自动热备份核心虚拟机 (100, 201, 202, 401) 并直推至局域网 NAS (10.10.11.x)
# 策略: 替换式备份（每个 VM 仅保留最新 1 套完整备份，自动清理历史旧包，节省 NAS 空间）
# ==============================================================================

set -eo pipefail

# NAS 主机 IP 与共享存储目录配置 (请根据实际情况配置)
NAS_HOST="${NAS_HOST:-10.10.11.195}"
NAS_USER="${NAS_USER:-admin}"
NAS_DIR="${NAS_DIR:-/share/NAS/PVE-Backup}"

PVE_DUMP_DIR="/var/lib/vz/dump"
TARGET_VMS=(100 201 202 401)
LOCAL_LOG="/var/log/pve_backup_nas.log"

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "${LOCAL_LOG}"
}

log "================================================================"
log "开始执行 PVE 核心虚拟机热快照并同步推送至 NAS 备份库..."
log "目标 NAS : ${NAS_USER}@${NAS_HOST}:${NAS_DIR}"
log "备份虚机 : ${TARGET_VMS[*]}"

# 1. 检查与 NAS 的免密连接
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${NAS_USER}@${NAS_HOST}" "true" 2>/dev/null; then
    log "❌ 错误: 无法免密连接到 NAS (${NAS_HOST})，请先打通 SSH 授权！"
    exit 1
fi
log "✓ 与 NAS 的内网 SSH 连接正常。"

# 2. 在 PVE 在线生成最新的快照备份 (静默模式，业务不中断)
log "⚡ 正在生成虚拟机快照备份 (vzdump snapshot zstd)..."
vzdump "${TARGET_VMS[@]}" --mode snapshot --compress zstd --storage local --quiet 1 || {
    log "⚠️  警告: vzdump 生成时有提示，继续执行同步..."
}
log "✓ PVE 本地快照备份生成完毕！"

# 3. 依次同步每个 VM 的最新备份文件直推 NAS
for vmid in "${TARGET_VMS[@]}"; do
    log "----------------------------------------------------------------"
    log "查找 VM [${vmid}] 的最新备份镜像..."
    LATEST_ARCHIVE=$(ls -t "${PVE_DUMP_DIR}"/vzdump-*-${vmid}-*.* 2>/dev/null | grep -E '\.(vma|tar)(\.(zst|gz|lzo))?$' | head -n 1 || true)

    if [[ -z "${LATEST_ARCHIVE}" ]]; then
        log "⚠️  警告: 未找到 VM [${vmid}] 备份文件，跳过！"
        continue
    fi

    BASE_PREFIX="${LATEST_ARCHIVE%.vma*}"
    BASE_PREFIX="${BASE_PREFIX%.tar*}"
    FILE_NAME=$(basename "${LATEST_ARCHIVE}")
    FILE_SIZE=$(ls -lh "${LATEST_ARCHIVE}" | awk '{print $5}')

    log "  - 准备推送: ${FILE_NAME} (${FILE_SIZE}) -> NAS..."
    rsync -av --partial "${BASE_PREFIX}"* "${NAS_USER}@${NAS_HOST}:\"${NAS_DIR}/\""
    log "✓ VM [${vmid}] 直推 NAS 成功！"
done

# 4. 在 NAS 端执行旧备份轮转清理 (每个 VM 仅保留最新 1 套)
log "----------------------------------------------------------------"
log "🧹 正在通知 NAS 执行历史备份替换清理..."

ssh "${NAS_USER}@${NAS_HOST}" bash -s -- "${NAS_DIR}" << 'EOF'
NAS_DIR="$1"
TARGET_VMS=(100 201 202 401)

cd "${NAS_DIR}" || exit 0
for vmid in "${TARGET_VMS[@]}"; do
    count=0
    for f in $(ls -t vzdump-*-${vmid}-*.vma.* 2>/dev/null); do
        count=$((count + 1))
        if [ "$count" -gt 1 ]; then
            pre="${f%.vma*}"
            rm -f "${pre}"*
        fi
    done
done
EOF

log "✓ NAS 历史版本替换轮转清理完毕。"

# 5. 记录日志到 NAS 共享目录
LOG_TIME=$(date '+%Y-%m-%d %H:%M:%S')
ssh "${NAS_USER}@${NAS_HOST}" "echo '[$LOG_TIME] PVE 每周日全自动备份与替换轮转完成。' >> '${NAS_DIR}/backup.log'"

log "================================================================"
log "🎉 PVE 虚拟机直推 NAS 备份任务圆满完成！"
log "================================================================"
