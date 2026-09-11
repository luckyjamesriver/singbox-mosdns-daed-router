# Debian 12 高性能旁路由全套搭建指南 🚀

> 基于 **Debian 12 + daed (eBPF) + Sing-box (1.14+) + mosdns** 的现代低延迟、高吞吐、高稳定旁路由全套架构方案。

---

## 🌟 架构演进与设计亮点

本项目记录了从传统 OpenWrt (PassWall + MosDNS) 切换到纯粹的 **Debian 12 Linux 旁路由** 的完整部署流程。相较于虚拟机 OpenWrt，原生 Linux 方案具有更好的内核资源调度、更高的网络吞吐与极佳的连接稳定性。

### 核心特性
1. **Linux 内核深度优化**：
   - 开启内核 `net.ipv4.ip_forward` 转发。
   - **🔴 彻底关闭 ICMP 重定向 (Send Redirects)**：解决局域网客户端与主路由同网段转发时的非对称路由与旁路失效问题。
   - 原生开启 **BBR** 拥塞控制算法，提升跨国高丢包线路表现。
   - 完整禁用 IPv6，规避国内运营商 IPv6 造成的代理漏网。
2. **Sing-box (1.14+) 极速代理核心**：
   - 适配最新的 Debian 12 **deb822 官方 APT 源**规范，支持 `apt` 一键安装与平滑升级。
   - 规避 Sing-box 1.12+ / 1.14+ 废弃语法，提供现代 **VLESS-Reality、Hysteria 2、TUIC v5** 出站规范。
   - 集成最新的 **MetaCubeXD** Web 控制面板（`:9090`），随时随地一键测速与手动切节点。
3. **daed (eBPF) 透明分流**：
   - 利用 Linux 内核级 eBPF 技术在协议栈顶层拦截转发，无需笨重的 iptables 规则链，CPU 占用极低。
4. **架构极简（彻底移除 Dnsmasq）**：
   - 旧方案中因早期配置调试曾临时使用 Dnsmasq 胶水层；**现已彻底弃用 Dnsmasq**。
   - DNS 直由 mosdns 进行国内外智能分流与防污染解析，链路更短、解析延迟更低。

---

## 📂 部署指南目录

请按照以下顺序依序配置：

| 步骤 | 说明文档 | 核心内容 |
| :--- | :--- | :--- |
| **步骤 0 (底层平台)** | [安装 PVE9](./安装%20PVE9) | 零刻 EQ12 小主机安装 Proxmox VE 9，规划双 2.5G 网卡与主备虚拟机 |
| **步骤 1** | [准备网络环境](./准备网络环境) | 配置静态 IP 与固定 DNS、开启内核转发、关闭 ICMP 重定向、持久化 iptables |
| **步骤 2** | [安装 sing-box](./安装%20sing-box) | APT deb822 安装 Sing-box 1.14+、Socks5 7891 进站、最新多协议出站及 MetaCubeXD |
| **步骤 3** | [安装 mosdns](./安装%20mosdns) | 安装 mosdns v5，配置国内外域名/IP 规则集与本地 DNS 缓存 |
| **步骤 4** | [安装 daed](./安装%20daed) | 安装 daed、配置 eBPF 透明代理分流规则、关联 Sing-box 节点 |
| **步骤 5 (进阶容灾)** | [安装 keepalived](./安装%20keepalived) | 克隆虚拟机搭建 Keepalived 双机高可用旁路由，实现 VIP 故障无缝漂移 |

---

## 💡 网络拓扑示例参考

```text
[ 局域网终端 (PC / 手机 / TV) ]
           │
           │ (DHCP 网关 & DNS 均指向 Keepalived VIP: 10.10.11.10)
           ▼
[ 零刻 EQ12 小主机 (PVE 9 宿主机: 10.10.11.2) ]
     ├─ [VM 100: Routers 主路由 (10.10.11.11, vmbr1-WAN + vmbr0-LAN)]
     │
     └─ [Keepalived 虚拟路由冗余 (VIP: 10.10.11.10)]
          ├── [VM 101: Debian 12 主机 A (10.10.11.7, priority 100)]
          └── [VM 102: Debian 12 备机 B (10.10.11.8, priority 90)]
                │
                ├─ daed (eBPF 流量劫持与路由判定)
                ├─ mosdns (:53 国内外精准分流防污染)
                └─ sing-box (:7891 出站代理核心)
                │
                │ (国内直连流量 / 代理外网流量出站)
                ▼
   [ 光猫 / 互联网 WAN ]
```

---

## 🙏 特别鸣谢与参考

- [SagerNet / Sing-box](https://github.com/SagerNet/sing-box)
- [daeuniverse / daed](https://github.com/daeuniverse)
- [IrineSistiana / mosdns](https://github.com/IrineSistiana/mosdns)
- [YouTube @billmike888](https://www.youtube.com/@billmike888)
- [YouTube @idevShare](https://www.youtube.com/@idevShare)
- [YouTube @孔昊天的折腾日记](https://www.youtube.com/@孔昊天的折腾日记)
