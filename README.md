# Auto-Seedbox-PT (ASP)

🚀 **专为 PT 玩家打造的终极服务器自动化部署与极限调优工具**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![System](https://img.shields.io/badge/System-Debian%20%7C%20Ubuntu-green.svg)]()
[![Architecture](https://img.shields.io/badge/Arch-x86__64%20%7C%20arm64-orange.svg)]()

**Auto-Seedbox-PT** 是一个高度智能化的 Shell 脚本，旨在彻底简化 PT 专用服务器（Seedbox）的部署流程。它不仅能一键安装 qBittorrent、Vertex 和 FileBrowser，更内置了极其硬核的**系统级内核调优引擎**。

无论你是使用昂贵的万兆独立服务器抢首发，还是使用便宜的轻量 VPS 长期养老，或者想要保种刷流的，ASP 都能根据你的硬件环境自动注入最完美的底层参数，榨干服务器的每一滴性能。

---

## ✨ 核心特性

### ⚔️ 双模调优引擎 (Dual-Mode Tuning)
首创场景化调优模式，拒绝一刀切的无脑打药：
* 🏎️ **极限刷流模式 (`-m 1`)**：专为大内存、NVMe 独服打造。强制锁定 CPU 最高睿频、暴增 TCP 发送/接收缓冲区至 1GB、注入 qBit 隐藏发包水位线黑科技，极致抢跑（内存不能低于4G）。
* 🛡️ **均衡保种模式 (`-m 2`)**：专为 保种刷流、长期自用VPS/NAS 等打造。极致释放 I/O 性能，保障低负载长期挂机，挂载数千种子亦稳如泰山（均衡模式依然进行特殊调优，只是并没有太过暴力）。
* 🧠 **硬件防呆机制**：若选择极限模式但机器物理内存 `<4GB`，脚本将强制介入并降级为均衡模式，100% 防止系统 OOM 死机。

### 📦 底层依赖精准锁定 (libtorrent Version Lock)
摒弃繁琐的手动试错，脚本会自动抓取静态编译包并匹配最完美的底层库：
* **v4 模式 (4.3.9)**：强制绑定 **libtorrent v1.2.x**。精准控制内存缓存，规避内存泄漏，PT 圈公认的神油养老版。
* **v5 模式 (最新/指定版)**：强制绑定 **libtorrent v2.0.x**。彻底禁用应用层缓存，拥抱 MMap (内存映射)。让 Linux 空闲内存全面接管 I/O，告别磁盘 100% 过载。

### 🌐 网络感知与极致容错
* **拥塞算法嗅探**：极限模式下，自动侦测并挂载系统内已有的 `BBRx` 或 `BBRv3` 等魔改算法；若无第三方内核则安全退回原生 BBR，绝不强行换内核导致机器变砖。
* **一键无缝搬家**：支持直接填入 ZIP 备份直链，自动还原 Vertex 数据，并**智能修正**配置文件中的 qBit 网关 IP 与面板密码。
* **踏雪无痕卸载**：`--purge` 模式不仅清理容器，更能将打药的 Sysctl 参数、网卡队列、甚至 CPU 调度策略动态回滚至系统初始状态。

---

## 🖥️ 环境要求

* 🐧 **操作系统**: Debian 10+ / Ubuntu 20.04+ (强烈建议在纯净系统下运行)
* ⚙️ **硬件架构**: x86_64 (AMD64) / aarch64 (ARM64)
* 🔑 **权限要求**: 必须使用 `root` 用户运行

---

## ⚡ 快速开始

> **💡 提示**：以下命令中的 `用户名` 和 `密码` 请自行替换。密码长度必须 **≥ 8 位**。

### 1. 极致抢跑（独立服务器 / 刷流首选）
安装最新版 qBittorrent v5 + 附加组件，启用 **极限刷流模式**（锁定 CPU，暴增网络并发）：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) -u admin -p 你的强密码 -q 5 -m 1 -v -f -t
```

### 2. 均衡养老（VPS / NAS 首选）
安装最稳的 qBittorrent 4.3.9 + 附加组件，启用 **均衡保种模式**（稳定低负载）：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) -u admin -p 你的强密码 -q 4.3.9 -m 2 -v -f -t
```

### 3. 精准版本 & 自定义端口（交互模式）
精准安装 `5.0.4` 版本，并使用 `-o` 参数在安装时手动指定各个组件的端口：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) -u admin -p 你的强密码 -q 5.0.4 -m 2 -v -f -t -o
```

### 4. 基础极简版（仅 qBittorrent）
不装面板和文件管理器，纯净部署 qBit 和基础系统优化：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) -u admin -p 你的强密码 -q 5 -m 2 -t
```

### 5. 一键搬家（恢复 Vertex 数据）
从旧服务器迁移，自动下载备份包并解压覆盖：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) -u admin -p 你的强密码 -m 2 -v -f -t -d "https://your-server.com/backup/vertex.zip" -k "zip_password"
```

---

## 📝 参数详解

| 参数 | 必填 | 描述 | 示例 |
|:---:|:---:|---|---|
| `-u` | ✅ | WebUI 及面板用户名 | `-u admin` |
| `-p` | ✅ | 统一密码（必须 ≥ 8 位） | `-p mysecurepass` |
| `-m` | ⭕ | **调优模式**：`1`(极限刷流) 或 `2`(均衡保种)。默认 `1` | `-m 1` |
| `-q` | ⭕ | qBit 版本：`4.3.9`、`5`、`latest` 或 `5.0.4` 等确切版本 | `-q 5.0.4` |
| `-c` | ⭕ | 缓存大小(MB)。*注：仅对 4.x 有效，5.x 使用 mmap 将被忽略* | `-c 2048` |
| `-v` | ⭕ | 部署 Vertex 面板 (Docker) | `-v` |
| `-f` | ⭕ | 部署 FileBrowser 文件管理器 (Docker) | `-f` |
| `-t` | ⭕ | 启用系统级内核与网络调优 (强烈推荐) | `-t` |
| `-o` | ⭕ | 自定义端口 (进入终端交互式询问) | `-o` |
| `-d` | ⭕ | Vertex 备份 ZIP 远程下载直链 | `-d http://...` |
| `-k` | ⭕ | Vertex 备份 ZIP 解压密码 (若无则不填) | `-k 123456` |

---

## 🗑️ 卸载与清理

本脚本自带极度硬核的卸载逻辑，支持系统状态无损回滚。

**🧹 普通卸载（仅删服务，保留用户数据和内核优化）**
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) --uninstall
```

**🔥 彻底清除（删库跑路级别）**
⚠️ **警告**：这将清除所有配置文件、容器映像，并**动态回滚** CPU 频率、TCP 缓冲区、拥塞窗口等内核参数至系统默认值！（默认保留 `Downloads` 下载目录防误删数据）
```bash
bash <(wget -qO- https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh) --purge
```

---

## ❓ 常见问题 (FAQ)

**Q: 到底选 v4 还是 v5？**

**A:** HDD，小内存等、挂几千个种子赚魔力（保种刷流），选 **v4 (4.3.9)**，内存控制极其优秀。大硬盘、大带宽、配合 Vertex 抢首发刷流，选 **v5 (如5.0.4)**，性能上限极高。

**Q: 为什么装了 v5，没跑多少流量系统内存就快满了？**

**A:** 正常现象。v5 底层默认使用 MMap（内存映射），Linux 会贪婪地把所有空闲内存当作磁盘读写的极速缓存（在面板中显示为 Cached/Buff）。**无需干预**，当其他程序需要内存时系统会自动瞬间释放。

**Q: 为什么我运行命令加了 `-m 1`，脚本却提示被降级了？**

**A:** 这是脚本的**内存防呆机制**生效了。极限模式会将 TCP 发送/接收缓冲区推高至 1GB，如果你的服务器物理内存小于 4GB，瞬间高并发会直接导致系统 OOM 崩溃。为了保护机器，脚本会自动介入降级到安全的均衡模式。

**Q: Vertex 连不上 qBit？下载器地址填 127.0.0.1 报错？**

**A:** Vertex 跑在 Docker 隔离环境里，`127.0.0.1` 指向的是容器内部。要连宿主机的 qBit，必须填 Docker 的网桥网关（通常是 `172.17.0.1`）。不必猜，**脚本安装完成后的高亮绿字提示中，已经为你计算输出了准确的内网连接 IP**，直接照着填即可。

**Q: Vertex 导入备份后，用之前的账号密码登不进去了？**

**A:** 脚本解压你的备份包时，会自动拦截并把配置文件里的旧账号密码，**强制覆盖**为你当前执行安装命令时传入的 `-u` 和 `-p`。直接用新设的密码登录即可。如果依旧失败，请手动查阅 `/root/vertex/data/setting.json`。

**Q: 打开 qBittorrent WebUI 提示 `Unauthorized` 错误？**

**A:** 
1. 局域网访问时，试着在浏览器地址后面加个斜杠绕过缓存（如 `http://IP:8080/`）。
2. 脚本默认已经关闭了 HostHeader 校验和 CSRF 保护，远程公网访问应该是直接畅通的。

**Q: 脚本运行直接报错 `syntax error` 或各种乱码符号？**

**A:** 一般是你在 Windows 下修改了脚本源码再上传，带入了 Windows 的 CRLF 换行符。推荐直接复制 README 里的 `wget` 命令在线跑，或者在本地编辑器（如 VSCode）把右下角的换行符改成 `LF` 再上传。

---

## 📜 协议与鸣谢

本项目基于 [MIT License](LICENSE) 开源。
内核极限调优思路参考了 [jerry048/Dedicated-Seedbox](https://github.com/jerry048/Dedicated-Seedbox) 和 [vivibudong/PT-Seedbox](https://github.com/vivibudong/PT-Seedbox) 的优秀设计，并进行了深度重构、环境防呆与场景化安全改造。您可以自由修改、分发，但请保留原作者署名。
