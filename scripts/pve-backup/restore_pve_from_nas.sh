#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: restore_pve_from_nas.sh
# 存放路径: scripts/pve-backup/restore_pve_from_nas.sh (或放在 NAS 备份目录下)
# 用途: 从 NAS 备份目录向 PVE 恢复虚拟机的灾难重建工具 (带安全防呆，严禁随意执行)
# 支持模式:
#   1. 单机恢复: ./restore_pve_from_nas.sh 201         (仅恢复指定 VMID)
#   2. 全量恢复: ./restore_pve_from_nas.sh all         (严格按 100 -> 201 -> 202 -> 401 拓扑顺序依次恢复)
# 特性:
#   - 极高安全防护: 必须手动输入大写 'CONFIRM' 才会真正触碰虚拟机
#   - 异机无缝支持: 支持原主机恢复或换全新小主机 (可指定 PVE_HOST)
#   - 智能识别源包: 若 PVE 节点已存在同名包则直接秒级还原，缺少则自动从 NAS 推流上传
# ==============================================================================

set -eo pipefail

# 默认 PVE 地址，也可通过环境变量指定: PVE_HOST=10.10.11.x ./restore_pve_from_nas.sh ...
PVE_HOST="${PVE_HOST:-10.10.11.2}"
PVE_USER="root"
PVE_DUMP_DIR="/var/lib/vz/dump"
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 安全拓扑恢复顺序 (主路由必须第一位)
TOPOLOGY_VMS=(100 201 202 401)

# 配色控制
GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
BOLD="\033[1m"
NC="\033[0m"

usage() {
    echo -e "${CYAN}使用方法:${NC}"
    echo -e "  $0 <VMID|all>"
    echo -e "示例:"
    echo -e "  $0 201        # 仅恢复 RouterA (VM 201)"
    echo -e "  $0 all        # 按网络依赖顺序全量恢复 (100 -> 201 -> 202 -> 401)"
    echo -e "若恢复到新小主机IP，可在命令前加环境变量，例如:"
    echo -e "  PVE_HOST=10.10.11.x $0 all"
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

TARGET="$1"
VMS_TO_RESTORE=()

if [[ "$TARGET" == "all" ]]; then
    VMS_TO_RESTORE=("${TOPOLOGY_VMS[@]}")
elif [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    VMS_TO_RESTORE=("$TARGET")
else
    echo -e "${RED}错误: 无效的目标参数 [$TARGET]，请输入具体的 VMID (如 201) 或 'all'。${NC}"
    exit 1
fi

echo -e "${RED}================================================================${NC}"
echo -e "${RED}${BOLD}             ⚠️   警告：即将从 NAS 执行 PVE 破坏性恢复流程         ${NC}"
echo -e "${RED}================================================================${NC}"
echo -e "目标主机   : ${YELLOW}${PVE_USER}@${PVE_HOST}${NC}"
echo -e "待恢复机器 : ${BOLD}${RED}${VMS_TO_RESTORE[*]}${NC}"
echo -e "NAS 存储源 : ${YELLOW}${LOCAL_DIR}${NC}"
echo -e "${RED}⚠️  注意：此操作将【彻底覆盖】PVE 对应虚拟机的当前硬盘与系统！${NC}"
echo -e "----------------------------------------------------------------"

# 1. 第一重防呆确认
read -r -p "你确定要继续执行恢复吗？请输入大写 'CONFIRM' 确认执行: " USER_INPUT
if [[ "$USER_INPUT" != "CONFIRM" ]]; then
    echo -e "${GREEN}安全退出，未进行任何修改。${NC}"
    exit 0
fi

# 2. 检查 SSH 免密连接
echo -e "\n🔍 正在检查与 PVE (${PVE_HOST}) 的 SSH 免密连接..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${PVE_USER}@${PVE_HOST}" "true" 2>/dev/null; then
    echo -e "${RED}❌ 错误: 无法免密连接到 ${PVE_USER}@${PVE_HOST}，恢复流程终止！${NC}"
    exit 1
fi
echo -e "${GREEN}✓ SSH 连接畅通。${NC}\n"

# 3. 逐台虚拟机执行安全恢复流水线
for vmid in "${VMS_TO_RESTORE[@]}"; do
    echo -e "${BLUE}================================================================${NC}"
    echo -e "🚀 准备恢复虚拟机 VM [${YELLOW}${vmid}${NC}]..."

    # 本地定位该 VMID 的最新备份包
    LOCAL_BACKUP=$(ls -t "${LOCAL_DIR}"/vzdump-*-${vmid}-*.vma.* 2>/dev/null | head -n 1 || true)
    if [[ -z "${LOCAL_BACKUP}" ]]; then
        echo -e "${RED}❌ 错误: 本地目录未找到 VM [${vmid}] 的有效备份文件 (.vma.*)！跳过。${NC}"
        continue
    fi

    ARCHIVE_BASENAME=$(basename "${LOCAL_BACKUP}")
    REMOTE_PATH="${PVE_DUMP_DIR}/${ARCHIVE_BASENAME}"

    echo -e "  - 命中备份镜像: ${CYAN}${ARCHIVE_BASENAME}${NC}"

    # 检查 PVE 远端是否存在该镜像
    PVE_HAS_FILE=$(ssh "${PVE_USER}@${PVE_HOST}" "[[ -f '${REMOTE_PATH}' ]] && echo 'yes' || echo 'no'")

    if [[ "$PVE_HAS_FILE" == "yes" ]]; then
        echo -e "  - ${GREEN}PVE 节点已存在此备份包，无需上传，直接进行就地还原！${NC}"
    else
        echo -e "  - ${YELLOW}PVE 节点缺少此文件，正在从 NAS 高速推流上传至 PVE...${NC}"
        rsync -avP --partial "${LOCAL_BACKUP}" "${PVE_USER}@${PVE_HOST}:${PVE_DUMP_DIR}/"
    fi

    # 检查当前虚机是否正在运行，如果运行中先停机
    VM_STATUS=$(ssh "${PVE_USER}@${PVE_HOST}" "qm status ${vmid} 2>/dev/null || echo 'not_exist'")
    if [[ "$VM_STATUS" =~ "status: running" ]]; then
        echo -e "  - 虚拟机正在运行，执行停机 (qm stop ${vmid})..."
        ssh "${PVE_USER}@${PVE_HOST}" "qm stop ${vmid}"
        sleep 2
    fi

    # 执行核心覆盖恢复
    echo -e "  - ${BOLD}${GREEN}正在执行 PVE 核心恢复 (qmrestore --force 1)...${NC}"
    ssh "${PVE_USER}@${PVE_HOST}" "qmrestore '${REMOTE_PATH}' ${vmid} --force 1"

    echo -e "  - ${GREEN}恢复完成！正在启动虚机 (qm start ${vmid})...${NC}"
    ssh "${PVE_USER}@${PVE_HOST}" "qm start ${vmid}"

    echo -e "${GREEN}✓ VM [${vmid}] 恢复并启动成功！${NC}"

    # 如果是全量恢复且当前是主路由 100，稍等 10 秒等待网络二层与 DHCP 建立
    if [[ "$TARGET" == "all" && "$vmid" == "100" ]]; then
        echo -e "${YELLOW}等待 10 秒以让主路由 (VM 100) 建立局域网网关与 DHCP...${NC}"
        sleep 10
    fi
    echo ""
done

echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}🎉 恢复流程已全部执行完成！请进入 PVE WebUI 或使用 ping 校验虚机连通性。${NC}"
echo -e "${CYAN}================================================================${NC}"
