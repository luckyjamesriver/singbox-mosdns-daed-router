# singbox-mosdns-daed-router

基于 PVE 9 虚拟化底座、RouterOS 纯净主路由与 Debian 12（daed eBPF + sing-box + mosdns + keepalived 双机高可用旁路由）的现代家庭网络架构方案。

> 配套服务端自动化部署脚本：[vps-sing-box](https://github.com/luckyjamesriver/vps-sing-box)（全 UDP 矩阵快速部署，客户端配置无缝对齐）。

---

### 架构特性

- **PVE 9 平台底座**：规划双网桥（`vmbr1` 外网拨号 / `vmbr0` 内网交换），开启 IOMMU 与 CPU Host 指令集直通。
- **RouterOS (CHR) 主路由**：专职 PPPoE 拨号、基础 NAT 与 DHCP 分发；下发网关与 DNS 指向 Keepalived VIP (`10.10.11.10`)。
- **Debian 12 + daed + sing-box 旁路由**：Linux 内核级 eBPF 链路层透明分流；搭载双线热备与抗封锁 UDP 矩阵（Hysteria 2 端口跳跃、TUIC v5、NaïveProxy）。
- **MosDNS v5 智能解析**：本地监听 `:53`，精准分流国内白名单与海外常用域名，内置大容量内存缓存，首屏秒开。
- **Keepalived 双机高可用**：Master (`10.10.11.7`) 与 Backup (`10.10.11.8`) 共享 VIP `10.10.11.10`，非抢占模式实现秒级无感容灾。
- **Tailscale DERP + 全能出口中枢**：独立轻量虚拟机 (`10.10.11.3`) 承载私有 DERP 中继、子网穿透与 Exit Node 出口，外出设备无感直连家庭内网并继承软路由分流出海。

---

### 极速部署

在 PVE 中完成 Debian 12 虚拟机基础安装并配置好静态 IP 与 SSH 后，执行一键流水线脚本即可自动安装 MosDNS v5、Sing-box 1.14+、MetaCubeXD 与 daed eBPF：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luckyjamesriver/singbox-mosdns-daed-router/main/setup.sh)
```

> 详细图文说明请参阅 [一键配置指南](./%E4%B8%80%E9%94%AE%E9%85%8D%E7%BD%AE.md)。

---

### 部署目录

| 章节 | 说明文档 | 核心内容 |
| :--- | :--- | :--- |
| 极速通道 | [一键配置指南](./%E4%B8%80%E9%94%AE%E9%85%8D%E7%BD%AE.md) | Debian 12 旁路由一键全自动部署脚本 |
| 步骤 00 | [00. 安装 PVE9](./00.安装%20PVE9.md) | 宿主机 BIOS 调优、系统安装与双网卡规划 |
| 步骤 01 | [01. 安装 RouterOS 虚拟机](./01.安装%20RouterOS%20虚拟机.md) | CHR 镜像导入、WAN/LAN 规划与 PPPoE/DHCP 配置 |
| 步骤 02 | [02. 安装 Debian12 虚拟机](./02.安装%20Debian12%20虚拟机.md) | 虚拟机创建、静态 IP 与内核网络调优 |
| 步骤 03 | [03. 安装 sing-box](./03.安装%20sing-box.md) | Sing-box 1.14+ 安装、双线 UDP 矩阵出站与 Web 面板 |
| 步骤 04 | [04. 安装 mosdns](./04.安装%20mosdns.md) | MosDNS v5 安装、国内外分流规则与本地缓存 |
| 步骤 05 | [05. 安装 daed](./05.安装%20daed.md) | daed eBPF 透明代理规则与分流绑定 |
| 步骤 06 | [06. 安装 keepalived](./06.安装%20keepalived.md) | 备机克隆与 VRRP 双机热备 (VIP: 10.10.11.10) |
| 步骤 07 | [07. 安装 HomeNet 监控仪表盘](./07.安装%20HomeNet%20监控仪表盘.md) | 原生 Python 零依赖轻量全网监控门户 |
| 步骤 08 | [08. 安装 Tailscale DERP 节点](./08.安装与配置%20Tailscale%20DERP%20节点.md) | 私有中继、内网穿透子网路由与出海出口三合一 |

---

### 网络拓扑

```text
               [ 互联网光猫 (宽带入户) ]
                           │
                           │ (物理直连 2.5G WAN 口 - enp2s0)
                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ x86 物理宿主机 (Proxmox VE 9 平台 / 双 2.5G 网卡 / 管理 IP: 10.10.11.2)        │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ [VM 100] RouterOS 主路由 (CHR v7.x)                                    │  │
│  │  - WAN 口 (vmbr1 -> enp2s0): PPPoE 拨号获取公网 IP / 光猫 DHCP          │  │
│  │  - LAN 口 (vmbr0 -> enp1s0): IP 10.10.11.1/24 (基础 NAT 转发)         │  │
│  │  - DHCP 服务: 网段 10.10.11.100-200, 网关 & DNS 均指向 VIP 10.10.11.10  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                      │ (vmbr0 内部虚拟局域网交换机)            │
│                                      ▼                                      │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ Keepalived 虚拟路由冗余高可用集群 (VIP: 10.10.11.10)                    │  │
│  │                                                                       │  │
│  │  ┌─────────────────────────────────┐   ┌───────────────────────────┐  │  │
│  │  │ [VM 101] 主旁路由 RouterA (主机) │   │ [VM 102] 从旁路由 RouterB │  │  │
│  │  │ - 物理 IP: 10.10.11.7 (ens18)    │   │ - 物理 IP: 10.10.11.8     │  │  │
│  │  │ - VRRP 优先级: 100 (Master)      │   │ - VRRP 优先级: 90 (Backup)│  │  │
│  │  │ - 模式: 双 BACKUP + nopreempt    │   │ - 模式: 双 BACKUP + noprem│  │  │
│  │  │ - daed (eBPF 透明代理分流)       │   │ - 镜像克隆相同分流服务栈   │  │  │
│  │  │ - mosdns (:53 国内外智能解析)    │   │                           │  │  │
│  │  │ - sing-box (:7891 四重协议核心)   │   │                           │  │  │
│  │  │ - check_dns.sh 业务级心跳探针    │   │                           │  │  │
│  │  └─────────────────────────────────┘   └───────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │ (物理网口 2.5G LAN 口 - enp1s0)
                                       ▼
                     [ 局域网物理交换机 / AP 路由器 ]
                                       │
                ┌──────────────────────┴──────────────────────┐
                ▼                                             ▼
     [ 有线终端 (PC / NAS / TV) ]                  [ 无线终端 (手机 / iPad / IoT) ]
     (获取 DHCP: 网关=10.10.11.10, DNS=10.10.11.10 -> 极速低延迟与秒级容灾)
```

---

### 维护与升级

项目配置了安全的自动化升级脚本，具备升级前语法校验、旧版本自动备份与失败自动回滚能力：

| 模块 | 升级命令 | 说明 |
| :--- | :--- | :--- |
| sing-box | `sudo /usr/local/bin/update-sing-box` | 获取 GitHub 最新 Release、自动校验配置语法并支持回滚 |
| mosdns | `sudo /usr/local/bin/update-mosdns` | 获取 GitHub 最新 Release、匹配 CPU 架构并平滑重启 |
| MetaCubeXD | `sudo /usr/local/bin/update_metacubexd.sh` | 拉取 GitHub 最新 gh-pages 构建并更新静态资源 |
| mosdns 规则 | `sudo /etc/mosdns/mos_rule_update.sh` | 更新国内直连白名单、防误判规则及广告黑名单 |

#### 节点重连小贴士
远端 VPS 节点重启或升级后，本地客户端长连接可能处于半开状态，可执行 `sudo systemctl restart sing-box` 秒级清空连接并触发探测，或在 `/etc/sing-box/config.json` 中将 `urltest` 的 `interval` 设为 `1m` 实现自动重连。

---

### 特别鸣谢与参考

- [RouterOS](https://mikrotik.com/) · [Proxmox VE](https://www.proxmox.com/) · [sing-box](https://github.com/SagerNet/sing-box) · [daed](https://github.com/daeuniverse) · [mosdns](https://github.com/IrineSistiana/mosdns)
- [Gitee @callmer](https://gitee.com/callmer) · [YouTube @billmike888](https://www.youtube.com/@billmike888) · [YouTube @idevShare](https://www.youtube.com/@idevShare) · [YouTube @孔昊天的折腾日记](https://www.youtube.com/@孔昊天的折腾日记)
