## 零刻 EQ12 + PVE 9 家庭全网加速与高可用软路由全套搭建指南 🚀

> 基于 **零刻 EQ12 (Intel i3-N300 双 2.5G) + Proxmox VE 9 + RouterOS 主路由 + Debian 12 (daed eBPF + Sing-box 1.14+ + MosDNS + Keepalived 双机高可用旁路由)** 的现代低延迟、高吞吐、高稳定全能家庭网络全套架构方案。

> [!TIP]
> **配套服务端脚本推荐**：如果您还没有自建翻墙节点，强烈推荐使用配套的自动化 VPS 部署项目 👉 **[vps-sing-box](https://github.com/luckyjamesriver/vps-sing-box)**，一键极速部署抗封锁全 UDP 矩阵（Hysteria 2 动态端口跳跃 + TUIC v5 + VLESS-Reality）。服务端安装完成后会自动导出专用于本旁路由的节点配置片段，两项目配置无缝对齐！

---

### 🌟 架构演进与设计亮点

本项目记录了从传统单体虚拟机 OpenWrt (PassWall + MosDNS) 演进到 **PVE 9 虚拟化底座 + RouterOS 纯净主路由 + Debian 12 双机热备 Linux 旁路由** 的完整部署流程。相较于传统方案，具备企业级的网络吞吐能力、强悍的抗故障容灾韧性与极致的代理性能。

#### 核心特性
1. **PVE 9 现代虚拟化平台 (零刻 EQ12 小主机)**：
   - 基于 8 核 Intel i3-N300 + 16G DDR5 + 500G NVMe SSD + 双 2.5G 网卡；
   - 规划 `vmbr1` (WAN 拨号直连光猫) 与 `vmbr0` (LAN 局域网桥接与各 VM 互联)；
   - 开启 IOMMU 硬件直通与 CPU Host 指令集直通，发挥加解密最高能效。
2. **RouterOS (CHR) 工业级主路由**：
   - 专职负责高速 PPPoE 宽带拨号、基础 NAT 转发与 DHCP 地址租约分发；
   - **核心联动**：DHCP 下发网关与 DNS 全权指向 Keepalived VIP (`10.10.11.10`)，主路由与旁路由职责清晰分离。
3. **Debian 12 + daed (eBPF) + Sing-box 1.14+ 极速旁路由**：
   - 采用 Linux 内核级 **eBPF** 技术在链路层截流分流，免去繁琐的 iptables，CPU 负载极低；
   - Sing-box 1.14+ 官方 deb822 源规范管理，搭载双线热备 (主力线路 + 备用线路) 与全 UDP/QUIC 强抗封锁矩阵 (Hysteria 2 动态端口跳跃 45000:50000、固定端口 Hysteria 2、TUIC v5、NaïveProxy HTTP/3 QUIC)，彻底免疫 GFW TCP 丢包阻断与 ISP 单端口 UDP QoS 限速；
   - 集成 MetaCubeXD Web 仪表板 (`:9090`) 实时测速与节点优选。
4. **MosDNS v5 国内外智能防污染分流**：
   - 本地轻量监听 `:53`，精准分流国内白名单直连与海外 AI/常用域名代理，搭配大容量内存缓存；
   - 彻底摒弃传统 Dnsmasq 胶水层，解析链路更短、首屏响应更快。
5. **Keepalived 双机秒级无感热备 (高可用容灾)**：
   - 通过 PVE 一键克隆生成 Master (`10.10.11.7`) 与 Backup (`10.10.11.8`) 双旁路由节点；
   - 共同持有 VIP `10.10.11.10`，采用 `nopreempt` 非抢占模式与 MosDNS 业务级心跳探针，任何单机维护重启均不影响全屋上网。

---

---

### ⚡ 极速起步：一键全自动部署旁路由核心服务

如果您已在 PVE 中安装好 Debian 12 虚拟机并配置好了静态 IP 与 SSH，可直接执行**一键全自动流水线脚本**，2 分钟内全自动安装完成（**MosDNS v5 + Sing-box 1.14+ + MetaCubeXD + daed eBPF**）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luckyjamesriver/singbox-mosdns-daed-router/main/setup.sh)
```

👉 **查看详细图文说明**: [【一键配置指南 (一键配置.md)】](./%E4%B8%80%E9%94%AE%E9%85%8D%E7%BD%AE.md)

---

### 📂 部署指南顺序目录（逐步深入与原理手册）

请按照以下顺序依序配置各模块：

| 章节顺序 | 说明文档 | 核心内容 |
| :--- | :--- | :--- |
| 🚀 **极速通道** | [一键配置指南](./%E4%B8%80%E9%94%AE%E9%85%8D%E7%BD%AE.md) | **Debian 12 旁路由一键全自动部署脚本** (MosDNS + Sing-box + daed + MetaCubeXD) |
| **步骤 00** | [00. 安装 PVE9](./00.安装%20PVE9.md) | 零刻 EQ12 BIOS 调优、PVE 9 系统安装、清华源配置、双 2.5G 虚拟网络与硬件直通 |
| **步骤 01** | [01. 安装 RouterOS 虚拟机](./01.安装%20RouterOS%20虚拟机.md) | 导入 CHR 官方 OVA/RAW 磁盘、WAN/LAN 接口规划、PPPoE 拨号与 DHCP VIP 网关下发 |
| **步骤 02** | [02. 安装 Debian12 虚拟机](./02.安装%20Debian12%20虚拟机.md) | 创建 4核4G VirtIO 虚拟机、ens18 静态 IP/DNS、开启 BBR、关闭 ICMP 重定向防环 |
| **步骤 03** | [03. 安装 sing-box](./03.安装%20sing-box.md) | APT deb822 安装 Sing-box 1.14+、Socks5 7891 进站、双线纯 UDP 矩阵出站 (Hy2 端口跳跃+TUIC+Naive) 与 MetaCubeXD 面板 |
| **步骤 04** | [04. 安装 mosdns](./04.安装%20mosdns.md) | 安装 mosdns v5，配置国内外域名/IP 规则集、分流策略与本地 DNS 缓存 |
| **步骤 05** | [05. 安装 daed](./05.安装%20daed.md) | 安装 daed v1.27.0+，配置 eBPF 透明代理规则、AI 平台分流与 ToWorld 节点绑定 |
| **步骤 06** | [06. 安装 keepalived](./06.安装%20keepalived.md) | PVE 克隆备机、部署 Keepalived VRRP 双机热备 (VIP: 10.10.11.10)、DNS 业务心跳检测 |

---

### 💡 全局网络拓扑架构图

```text
               [ 互联网光猫 (宽带入户) ]
                           │
                           │ (物理直连 2.5G WAN 口 - enp2s0)
                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 零刻 EQ12 物理主机 (Intel i3-N300 / 16G DDR5 / 500G SSD / 双 2.5G 网卡)      │
│ Proxmox VE 9 宿主机 (管理 IP: 10.10.11.2)                                    │
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
     (获取 DHCP: 网关=10.10.11.10, DNS=10.10.11.10 -> 享受极速低延迟与全自动高可用容灾)
```

---

### 🧰 核心服务日常维护与升级

项目针对生产环境配置了完备的安全升级脚本，具备**升级前语法校验、旧版本自动备份与失败自动回滚**能力：

| 服务模块 | 升级命令 | 说明 |
| :--- | :--- | :--- |
| **⚡ Sing-box 核心** | `sudo /usr/local/bin/update-sing-box` | 302 重定向获取 GitHub 最新 Release、自动检验 config.json 语法、双路径同步并秒级回滚 |
| **🌐 MosDNS 核心** | `sudo /usr/local/bin/update-mosdns` | 302 重定向获取 GitHub 最新 Release、自动匹配 CPU 架构、多镜像容灾下载与平滑重启 |
| **📊 MetaCubeXD WebUI** | `sudo /usr/local/bin/update_metacubexd.sh` | 拉取 GitHub 最新 gh-pages 前端构建并更新静态资源 |
| **📋 MosDNS 规则集** | `sudo /etc/mosdns/mos_rule_update.sh` | 更新国内直连白名单、淘宝防误判规则及广告黑名单 |

#### 💡 运维排错小贴士：远端 VPS 节点升级/重启后快速重连
* **现象**：当远端 VPS 的 sing-box 服务升级或重启后，本地旁路由可能无法立即恢复连通，甚至需要手动切换备用线路。
* **原因剖析**：
  1. 服务端进程重启会切断旧连接，而本地客户端长连接（Reality TCP 零拷贝直通、gRPC 流、TUIC/Hy2 QUIC 会话）可能处于半开超时等待状态；
  2. `urltest` 自动测速组存在轮询间隔（默认 3~5 分钟），在此期间本地仍将该节点标记为故障。
* **秒连技巧**：
  - **手动秒连（推荐 SOP）**：远端 VPS 重启完毕后，**立即在本地旁路由执行 `sudo systemctl restart sing-box`**（或在 MetaCubeXD 面板中重载）。重启瞬间会清空所有半开死连接并强制触发首轮即时测速，实现秒级重连。
  - **配置自愈优化**：在 `/etc/sing-box/config.json` 中，将 `urltest` 测速组的 `interval` 缩短至 `1m`（或 30s），`tolerance` 设为 `50`，即可在 VPS 恢复后 1 分钟内全自动探测重连，无需人工干预。

---

### 🙏 特别鸣谢与参考

- [MikroTik / RouterOS](https://mikrotik.com/)
- [Proxmox VE (PVE)](https://www.proxmox.com/)
- [SagerNet / Sing-box](https://github.com/SagerNet/sing-box)
- [daeuniverse / daed](https://github.com/daeuniverse)
- [IrineSistiana / mosdns](https://github.com/IrineSistiana/mosdns)
- [Gitee @callmer / PVE & RouterOS 折腾笔记](https://gitee.com/callmer)
- [YouTube @billmike888](https://www.youtube.com/@billmike888)
- [YouTube @idevShare](https://www.youtube.com/@idevShare)
- [YouTube @孔昊天的折腾日记](https://www.youtube.com/@孔昊天的折腾日记)
