# Auto-Seedbox-PT (ASP)

🚀 **专为 PT 玩家打造的终极服务器自动化部署与极限调优工具**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![System](https://img.shields.io/badge/System-Debian%20%7C%20Ubuntu-green.svg)]()
[![Architecture](https://img.shields.io/badge/Arch-x86__64%20%7C%20arm64-orange.svg)]()

**Auto-Seedbox-PT** 是一个高度智能化的 Shell 脚本，旨在彻底简化 PT 专用服务器（Seedbox）的部署流程。它不仅能一键安装 qBittorrent、Vertex 和 FileBrowser，更内置了极其硬核的**系统级内核调优引擎**。

无论你是使用昂贵的万兆独立服务器抢首发，还是使用便宜的轻量 VPS 长期养老，或者想要保种刷流的，ASP 都能根据你的硬件环境**自动注入最完美的底层参数以及qBittorrent配置参数**，榨干服务器的每一滴性能。

---

## ✨ 核心特性

### ⚔️ 双模调优引擎 (Dual-Mode Tuning)
首创场景化调优模式，拒绝一刀切的无脑打药：
* 🏎️ **极限刷流模式 (`-m 1`)**：专为大内存、NVMe 独服打造。强制锁定 CPU 最高睿频、暴增 TCP 发送/接收缓冲区至 1GB、彻底解除 Socket 并发封印，并针对高并发网络环境深度优化（内存不能低于4G）。
* 🛡️ **均衡保种模式 (`-m 2`)**：专为保种刷流、长期自用 VPS/NAS 等打造。极致释放 I/O 性能，保障低负载长期挂机，挂载数千种子亦稳如泰山（均衡模式依然进行特殊调优，只是并没有太过暴力，侧重于保护机械硬盘和系统稳定）。
* 🧠 **硬件防呆机制**：若选择极限模式但机器物理内存 `<4GB`，脚本将强制介入并降级为均衡模式，100% 防止系统 OOM 死机。

### 📦 底层依赖精准锁定 (libtorrent Version Lock)
摒弃繁琐的手动试错，脚本会自动抓取静态编译包并匹配最完美的底层库：
* **v4 模式 (4.3.9 + v1 引擎)**：强制绑定 **libtorrent v1.2.x**。精准控制内存缓存，规避内存泄漏，单核效率极高，是 PT 圈公认的保种神油养老版。
* **v5 模式 (最新/指定版 + 极致 I/O)**：强制绑定 **libtorrent v2.0.x**。彻底颠覆传统的内存映射（MMap）带来的卡顿，脚本会**强制接管 v5.x 的底层设定，开启 POSIX 和 Direct I/O（绕过系统缓存）**。配合大内存与高速 NVMe，彻底释放硬件潜能，是目前万兆网络抢首发的最强利器。

### 🌐 网络感知与极致容错
* **拥塞算法智能嗅探**：极限模式下，自动侦测并挂载系统内已有的 `BBRx` 或 `BBRv3` 等魔改算法；若无第三方内核则安全退回原生 BBR，绝不强行换内核导致机器变砖。
* **一键无缝搬家**：支持直接填入 ZIP 备份直链，自动还原 Vertex 数据。内置强大的 Python 清洗引擎，无惧任何外壳嵌套或 BOM 乱码，**智能展平数据结构**并精准替换 qBit 网关 IP 与面板密码。
* **踏雪无痕卸载**：`--uninstall` 模式不仅清理容器，更能将打药的 Sysctl 参数、脏页回写策略、网卡队列、甚至 CPU 调度策略动态回滚至系统初始状态。

---

## 🚀 架构解析：为何在 5.x 核心下强开 POSIX + Direct I/O？

绝大多数硬核玩家对 qBittorrent 5.x（基于 libtorrent v2）避之不及，其技术原罪在于：默认引入的 **MMap (内存映射文件)** 机制在面对万兆网络极高吞吐的随机区块写入时，会瞬间击穿 Linux 内核的 Page Cache 水位线，引发灾难性的 VFS Cache Thrashing（缓存抖动）。此时内核被迫挂起进程并频繁唤醒 `kswapd0` 进行同步阻塞级的 Dirty Page Writeback（脏页回写），最终导致严重的 I/O Wait 飙升、内核态 CPU 中断打满，表现为断崖式掉速与进程假死。

**ASP 脚本的底层解法：**
妥协退回 4.x 绝非最优解。ASP 脚本在实例首次初始化的关键期，会直接在文件系统层面对 `qBittorrent.conf` 进行硬编码劫持，强制注入 `DiskIOType=2` (POSIX 模式)，并对读写双端挂载等效于 `O_DIRECT` 的标志位（Disable OS cache）。

这一操作直接剥夺了 Linux 调度器对 I/O 缓存的干预权，使海量数据流完全绕过 VFS 缓存层，实现网卡到 NVMe 总线的 Direct I/O 直通。再辅以脚本自动分配的 32 线程 `POSIX aio` 异步队列池与自适应 Hashing Threads，彻底打通万兆刷流的底层任督二脉，将单机吞吐推向物理硬件的绝对极限。

---

## 🖥️ 环境要求

* 🐧 **操作系统**: Debian 10+ / Ubuntu 20.04+ (强烈建议在纯净系统下运行)
* ⚙️ **硬件架构**: x86_64 (AMD64) / aarch64 (ARM64)
* 🔑 **权限要求**: 必须使用 `root` 用户运行

---

## ⚡ 快速开始

> **💡 提示**：以下命令中的 `用户名` 和 `密码` 请自行替换。密码长度必须 **≥ 8 位**。

### 1. 极致抢跑（独立服务器 / 刷流首选）
安装最新版 qBittorrent v5 + 附加组件，启用 **极限刷流模式**（锁定 CPU，暴增网络并发，开启 Direct I/O）：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) -u 用户名 -p 密码 -q 5 -m 1 -v -f -t
```

### 2. 均衡模式（保种刷流 首选）
安装最稳的 qBittorrent 4.3.9 + 附加组件，启用 **均衡保种模式**（稳定低负载，大缓存）：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) -u 用户名 -p 密码 -q 4.3.9 -m 2 -v -f -t
```

### 3. 自定义端口（交互模式）
使用 `-o` 参数在安装时手动指定各个组件的端口：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) -u 用户名 -p 密码 -v -f -t -o
```

### 4. 精准版本 & 自定义端口（交互模式）
精准安装 `5.0.4` 版本，并使用 `-o` 参数在安装时手动指定各个组件的端口：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) -u 用户名 -p 密码 -q 5.0.4 -v -f -t -o
```

### 5. 基础极简版（仅 qBittorrent）
不装面板和文件管理器，纯净部署 qBit 和基础系统优化：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) -u 用户名 -p 密码 -q 5 -m 2 -t
```

### 6. 一键搬家（恢复 Vertex 数据模式）
从旧服务器迁移，自动下载备份包，智能展平嵌套结构，并抹平配置覆盖原有密码：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) -u 用户名 -p 密码 -m 2 -v -f -t -d "https://your-server.com/backup/vertex.zip" -k "zip_password"
```

---

## 📝 参数详解

| 参数 | 必填 | 描述 | 示例 |
|:---:|:---:|---|---|
| `-u` | ✅ | WebUI 及面板用户名 | `-u admin` |
| `-p` | ✅ | 统一密码（必须 ≥ 8 位） | `-p mysecurepass` |
| `-m` | ⭕ | **调优模式**：`1`(极限刷流) 或 `2`(均衡保种)。默认 `1` | `-m 1` |
| `-q` | ⭕ | qBit 版本（默认5.0.4）：`4.3.9`、`5`、`latest` 或 `5.0.4` 等确切版本 | `-q 5.0.4` |
| `-c` | ⭕ | 强制指定缓存大小(MB)。*若不填，脚本将根据物理内存自动计算最佳值* | `-c 4096` |
| `-v` | ⭕ | 部署 Vertex 面板 (Docker) | `-v` |
| `-f` | ⭕ | 部署 FileBrowser 文件管理器 (Docker) | `-f` |
| `-t` | ⭕ | 启用系统级内核与网络调优 (强烈推荐) | `-t` |
| `-o` | ⭕ | 自定义端口 (进入终端交互式询问) | `-o` |
| `-d` | ⭕ | Vertex 备份 zip或tar.gz 远程下载直链 | `-d http://...` |
| `-k` | ⭕ | Vertex 备份 zip或tar.gz 解压密码 (若无则不填) | `-k 123456` |

---

## 🗑️ 卸载与清理

本脚本自带极度硬核的卸载逻辑，支持系统状态无损回滚。

**🔥 彻底卸载（删库跑路级别）**
⚠️ **警告**：这将清除所有配置文件、容器映像，并**动态回滚** CPU 频率、TCP 缓冲区、拥塞窗口等所有深层内核参数至系统默认值！（交互中可选择是否保留 `Downloads` 下载数据目录）
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) --uninstall
```

---

## ❓ 常见问题 (FAQ)

**Q: 到底选 v4 还是 v5？**

**A:** HDD、小内存机器，或者想要进行保种刷流，选 **v4 (4.3.9)**，内存控制极其优秀。如果是大固态硬盘（NVMe）、大带宽、配合 Vertex 抢首发刷流，强烈建议选 **v5 (如 5.0.4)**！在 ASP 脚本独特的 Direct I/O 底层调教下，5.x 的性能上限远超 4.3.9，完全不存在原版 5.x 令人诟病的假死问题。

**Q: 为什么极限模式没有自动安装 BBRx 或者 BBRv3？**

**A:** 极限模式（默认或者 `-m 1`），会自动智能判断系统是否已安装 BBRx 或者 BBRv3。如果有，脚本将**自动激发**其潜能；但脚本**不会强制为您安装**新的内核，以防止出现底层驱动不兼容导致服务器无法开机变砖的情况。如果您追求极致，请自行修改内核，脚本会自行适应。

**Q: 为什么我运行命令加了 `-m 1`，脚本却提示被降级了？**

**A:** 这是脚本的**内存防呆机制**生效了。极限模式会将系统的 TCP 发送/接收缓冲区推高至近乎变态的程度，如果你的服务器物理内存小于 4GB，瞬间的极速高并发会直接导致系统内核 OOM 崩溃。为了保护机器，脚本会自动介入，将内核参数降级到安全的均衡模式。

**Q: Vertex 连不上 qBit？下载器地址填 127.0.0.1 报错？**

**A:** Vertex 跑在 Docker 隔离环境里，`127.0.0.1` 指向的是容器内部。要连宿主机的 qBit，必须填 Docker 的网桥网关（通常是 `172.17.0.1`）。不必猜，**脚本安装完成后的高亮绿字提示中，已经为你计算并输出了准确的内网直连 IP**，直接照着填即可。

**Q: Vertex 导入旧备份后，用之前的账号密码登不进去了？**

**A:** 无论您的备份包嵌套了多少层外壳，或者配置文件是否存在奇怪的换行符，ASP 脚本在解压时都会启动内置的清洗引擎。它会自动将旧配置里的账号密码，**强制覆盖**为您当前执行安装命令时传入的 `-u` 和 `-p`。直接用刚才新设的密码登录即可！

**Q: 为什么不加 `-c` 参数，qB 也能正常运行？**

**A:** 脚本引入了聪明的**动态缓存计算逻辑**。如果你不加 `-c`，脚本会侦测你的系统物理内存，在极限模式下自动划拨 35% 作为高速缓存，在均衡模式下划拨 15%（最高 2GB），省去小白计算的烦恼。如果你加了 `-c`（如 `-c 4096`），脚本则会绝对服从你的指令，将缓存强制锁死在指定值。

**Q: 打开 qBittorrent WebUI 提示 `Unauthorized` 错误？**

**A:** 1. 局域网访问时，试着在浏览器地址后面加个斜杠绕过缓存（如 `http://IP:8080/`）。
       2. 脚本默认已经关闭了 HostHeader 校验和 CSRF 保护，远程公网访问应该是直接畅通的。


---

## 📜 协议与鸣谢

本项目基于 [MIT License](LICENSE) 开源。
内核极限调优思路参考了 [jerry048/Dedicated-Seedbox](https://github.com/jerry048/Dedicated-Seedbox) 和 [vivibudong/PT-Seedbox](https://github.com/vivibudong/PT-Seedbox) 的优秀设计，并进行了深度重构、环境防呆与场景化安全改造。您可以自由修改、分发，但请保留原作者署名。
