# Auto-Seedbox-PT (ASP)

一键部署 PT 盒子环境的 Shell 脚本，集成 qBittorrent、Vertex 和 FileBrowser，内置硬核系统级调优引擎。无论你是独立服务器抢首发，还是轻量 VPS 长期养老，都能一键配置到位。

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## ✨ 核心特性

- **双模系统调优**：
  - `极限模式 (-m 1)`：为大内存独服/NVMe定制。锁定CPU最高频、暴力扩容 TCP 缓冲区至 1GB、注入 qBit 发包水位线黑科技，专为抢首发打造。（附带内存防呆：低于 4GB 自动降级，防 OOM）。
  - `均衡模式 (-m 2)`：为普通 VPS/NAS 定制。温和释放 I/O 性能，保障长期挂机稳定。
- **底层依赖精准绑定**：qBit 4.x 强制绑定 libtorrent v1.2 (规避内存泄漏)，5.x 强制绑定 v2.0 (拥抱 MMap 与 io_uring)。
- **自由版本控制**：支持 `-q 5.0.4` 这种精准小版本安装，也支持 `-q latest` 追新，或默认使用神油版本 4.3.9。
- **智能网络嗅探**：极限模式下自动检测并挂载 `BBRx` / `BBRv3`，无第三方内核则安全回退默认 BBR，不强行换内核防失联。
- **无痕纯净卸载**：`--purge` 彻底卸载不仅删服务，还会把 CPU 调度器、网卡队列、Sysctl 参数 1:1 无损回滚至安装前状态。
- **一键搬家**：支持 Vertex 备份包直链导入，并自动修正下载器网关 IP 与面板密码。

## 🖥️ 环境要求
- **系统**: Debian 10+ / Ubuntu 20.04+ (建议纯净系统)
- **架构**: x86_64 / aarch64
- **权限**: 必须使用 root 运行

## ⚡ 快速开始

**1. 极致抢跑（独立服务器 / 大内存专机）**
安装 qBit 5.x最新版 + 附加组件，启用极限模式：
```bash
bash <(wget -qO- [https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh](https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh)) -u admin -p 你的强密码 -q 5 -m 1 -v -f -t
```

**2. 均衡养老（VPS / NAS / 家用宽带）**
安装最稳的 qBit 4.3.9 + 附加组件，启用均衡模式：
```bash
bash <(wget -qO- [https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh](https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh)) -u admin -p 你的强密码 -q 4.3.9 -m 2 -v -f -t
```

**3. 精准版本与自定义端口（交互模式）**
安装指定的 5.0.4 版本，并在安装时手动设置各组件端口：
```bash
bash <(wget -qO- [https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh](https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh)) -u admin -p 你的强密码 -q 5.0.4 -m 2 -v -f -t -o
```

**4. Vertex 一键搬家**
```bash
bash <(wget -qO- [https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh](https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh)) -u admin -p 你的强密码 -m 2 -v -f -t -d "[http://你的备份链接.zip](http://你的备份链接.zip)" -k "解压密码"
```

## 📝 参数说明

| 参数 | 说明 | 示例 |
|---|---|---|
| `-u` | (必填) WebUI及面板用户名 | `-u admin` |
| `-p` | (必填) 统一密码（必须 ≥ 8 位） | `-p mysecurepass` |
| `-m` | 调优模式：`1`(极限刷流) 或 `2`(均衡保种)。默认1 | `-m 1` |
| `-q` | qBit版本：`4`(4.3.9)、`5`(最新)、`5.0.4`等精确版本 | `-q 5.0.4` |
| `-c` | 缓存(MB)，仅4.x有效，5.x使用mmap该参数将被忽略 | `-c 2048` |
| `-v` / `-f`| 安装 Vertex / FileBrowser (Docker部署) | `-v -f` |
| `-t` | 应用系统级内核与网络调优 (强烈推荐) | `-t` |
| `-o` | 自定义端口 (安装时终端提示输入，并检测冲突) | `-o` |
| `-d` / `-k`| Vertex 备份包 URL / 解压密码 | `-d http://...` |

## 🗑️ 卸载清理

- **普通卸载（保留数据与内核优化）：**
  ```bash
  bash <(wget -qO- [https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh](https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh)) --uninstall
  ```
- **彻底清除（无痕回滚）：**
  清理所有配置、Docker 容器，并**将所有系统内核/网络调优参数回滚到系统默认值**。（保留 Downloads 文件夹防误删）。
  ```bash
  bash <(wget -qO- [https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh](https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/main/auto_seedbox_pt.sh)) --purge
  ```

## ⚠️ 常见问题 (FAQ)

**Q: 选 v4 还是 v5？** A: 小内存 VPS、主要挂种子赚魔力（保种），选 **v4 (4.3.9)**，内存控制极其优秀。大硬盘、大带宽、专门抢首发刷流，选 **v5 (如5.0.4)**，性能上限极高。

**Q: 为什么装了 v5，系统内存没跑满带宽就快占满了？** A: 正常现象。v5 底层默认使用 MMap（内存映射），Linux 会把所有空闲内存作为磁盘的读写缓存（显示为 Cached）。不需要干预，别的程序要用内存时系统会自动释放。

**Q: 为什么我选了 -m 1，安装时提示我被降级到均衡模式了？** A: 脚本内置防呆机制。极限模式会暴增 TCP 缓冲区，物理内存不到 4GB 强行跑会直接死机（OOM），所以脚本保护性切回安全模式了。

**Q: Vertex 连不上 qBit？下载器地址填 127.0.0.1 报错？** A: Vertex 跑在 Docker 里，`127.0.0.1` 指的是容器内部。要连宿主机的 qBit，必须填 Docker 的网桥网关（通常是 `172.17.0.1`）。脚本安装完的绿色结果提示里会直接输出正确的网关地址，照着填就行。

**Q: Vertex 导入备份后，用户名密码错误登不进去？** A: 脚本解压备份时，会自动把配置里的老账号密码覆盖成你这次安装传的 `-u` 和 `-p`。直接用新设的密码登录即可。如果依旧失败，去 `/root/vertex/data/setting.json` 检查一下。

**Q: qBit WebUI 报 Unauthorized 错误？** A: 局域网访问时，试着在浏览器地址后面加个斜杠绕过缓存（如 `http://IP:8080/`）。脚本默认已经关了 HostHeader 校验和 CSRF 保护，远程访问应该是直接畅通的。

**Q: 脚本运行直接报 `syntax error`？** A: 一般是你在 Windows 下修改源码后上传，带入了 CRLF 换行符。推荐直接用终端 `wget` 跑在线版，或者在本地编辑器改成 LF 格式再上传服务器。

---
*基于开源社区优质脚本（Dedicated-Seedbox 等）重构，保留硬核调优精髓，并彻底解决其对普通家用/小鸡环境的水土不服问题。*
