# VPS 一键重装脚本

用于**只有一块磁盘的 Linux VPS / 轻量主机**。支持网络安装，或流式下载 gzip 压缩的完整 raw 磁盘镜像并覆盖磁盘。允许 HTTP 下载，不要求预先缓存完整镜像。

执行会清空磁盘。请准备服务商控制台；开始写盘后无法恢复原系统。服务器上的防火墙配置不会自动修改服务商的安全组。

## 使用

```bash
curl -fsSL -k -o dd.sh https://raw.githubusercontent.com/ZhuangJiayu/dd/master/dd.sh && bash dd.sh
```

也可以使用 jsDelivr：

```bash
curl -fsSL -k -o dd.sh https://fastly.jsdelivr.net/gh/ZhuangJiayu/dd@latest/dd.sh && bash dd.sh
```

远程命令获取的是已发布版本；本地尚未发布的修改不会自动出现在下载地址中。本文描述本目录的 `dd.sh`。默认 root 密码仍为 `haoduck.com`，默认 SSH 端口仍为 `22`，静态 IPv4 仍是默认网络模式。密码输入不回显；命令行密码请用单引号保护 Shell 特殊字符，最多 128 字节，不支持换行。

```bash
# Debian 13，安装环境和新系统均使用 DHCP
bash dd.sh -d 13 --dhcp -p '自定义密码' -port 2222

# Debian 12，静态网络；不填写时从当前出口接口提取
bash dd.sh -d 12 --static \
  --ip-addr 192.0.2.10 --ip-mask 255.255.255.255 \
  --ip-gate 198.51.100.1 --ip-dns '8.8.8.8 1.1.1.1'

# 通用镜像只写盘，不修改镜像内的网络、账号或 SSH
bash dd.sh -dd 'http://example.com/disk.raw.gz' --dhcp

# Windows 镜像的网络、RDP 和系统卷扩容适配
bash dd.sh -dd 'http://example.com/windows.raw.gz' --image-type windows --dhcp -rdp 3389

bash dd.sh --help
```

无参数进入交互菜单。1–8 进行网络安装，9–11 使用预设的 Linux 镜像，99 展开历史镜像 12–36，也可以直接输入编号。100 接受自己的镜像直链，可选择只写盘或 Windows 适配。有参数时直接按参数执行。清盘确认会显示最终系统或镜像、适配方式和网络模式。显示的镜像地址会隐去认证信息、查询串和片段。直接回车开始，输入其他内容取消。`--yes` / `-y` 跳过确认。

项目统一使用 `dd.sh`。此前修复版中的优化和修复已全部合入此文件，下载、运行和后续维护均使用 `dd.sh`。

`source dd.sh` 只初始化函数和入口路径。保留旧函数名 `InstallNET_Main`，**显式调用它会通过独立 Bash 启动重装流程**。保留 `-apt` / `-yum` 镜像源别名；旧版原本不做处理的 `-m` / `--manual` / `-ssl` 继续作为兼容空操作，不表示手动安装或启用额外 TLS 校验。`-i` / `--interface` 仍表示安装器网卡选择，自动探测网络参数仍以当前出口接口为准。按本次需求删除 `--loader` 导出功能，不提供复杂任务状态系统。

## 系统和镜像

| 目标 | 模式 | 配置能力 |
| --- | --- | --- |
| Debian 13 / 12 / 11 / 10 | 网络安装 | 密码、SSH 端口、DHCP / 静态 IPv4 |
| Ubuntu 20.04 / 18.04 / 16.04 | legacy 网络安装 | 密码、SSH 端口、DHCP / 静态 IPv4 |
| CentOS 6.10 | 网络安装，amd64 / i386 BIOS | 密码、SSH 端口；离网段网关请使用 DHCP 或其他系统 |
| 菜单中的 CentOS 7.8 / 7.6、Rocky Linux 8.6、历史 CentOS 8（23） | 镜像覆盖，amd64 BIOS | ext2/3/4 或 XFS 普通根分区，ifcfg 网络配置，密码、SSH 端口 |
| 历史 Windows 镜像（12–22、24–36） | 镜像覆盖，沿用原编号与地址 | 25、27、29、31 需要 UEFI。Windows Server 2003（18、20）只写盘，使用镜像自身的网络及登录设置 |
| 自定义完整 raw.gz | 镜像覆盖 | 只写盘，镜像自行提供适合 VPS 的引导、网络和登录配置 |

系统列表表示菜单保留的安装路径，不代表所有“版本 × 架构 × 引导方式”组合已经实测。为保留旧内部参数映射，命令行仍接受 Debian 7/8/9、Ubuntu 12.04/14.04 及 CentOS 6.x；它们没有新增菜单项，上游仓库是否可用、旧内核是否适合宿主仍需另行确认。

镜像需要能解压成可直接写盘的完整磁盘数据。部分历史地址带有 `.vhd.gz` 后缀，实际内容由第三方维护。脚本没有 ISO、QCOW2 或动态 VHD 转换功能。本次没有验证第三方链接仍有效、返回直链或包含可启动的镜像。

镜像覆盖时使用 Debian 11 安装环境。写盘前检查整盘和分区的挂载、交换设备、LVM / RAID 等活动映射，并要求内核能重读现有分区表。仍在使用就停止。首个扇区到达后会再次检查占用，再开始写入。流式下载的 gzip 完整性校验要到流结束时才能完成，中途失败仍可能已覆盖部分磁盘。

## 环境要求与范围

- 使用 root 在完整 Linux 虚拟机中运行；不支持 OpenVZ / 容器。
- 保留 GRUB 2 和 BIOS GRUB Legacy 两条引导路径。GRUB 2 使用 `probe`、`mkrelpath`、`script-check`、`editenv` 工具；Legacy 沿用首个启动项（必须是 Linux）的根设备与路径约定，不强制安装 GRUB 2 工具。
- 不因为 `/boot` 位于 LVM / RAID / Btrfs 等布局就一律拒绝；GRUB 工具仍须能够解析安装文件所在文件系统和路径。未适配 Secure Boot、EFI Legacy、UEFI i386 安装器及菜单中的 BIOS RHEL 镜像在 UEFI 上启动。
- 根据宿主架构和目标版本选择安装器；不是每个版本都提供 amd64、i386、arm64 的全部组合。不支持 UEFI 上的 i386 安装器。内核及 initrd 在修改引导前下载、解包和重新打包检查。
- 保留现有内核文件，新增独立 `/boot/dd-reinstall.*` 目录。原 GRUB 配置保存在该目录；本次准备或重启失败时恢复配置。
- 普通 ext2/3/4 或 XFS 上的 GRUB 2 使用独立一次性环境标记，清除成功后才选择安装项，不修改系统原来的 `grubenv`。Legacy 或无法安全写回标记的布局保留旧式持久默认项方式；安装成功会由新系统替换引导，失败后手动重启时需通过控制台选择恢复项，不能把此方式称为一次性启动。
- 静态网络按出口网卡 MAC 绑定为 `ddnet0`，保留 `/32`，为网关配置必要主机路由。不自动把掩码改成 `/24`，不迁移复杂策略路由或额外业务网卡。
- 已适配 RHEL 镜像需要可直接挂载的普通根分区；不支持 LVM / 加密卷。非 22 端口且 SELinux 开启时，目标镜像需要 `semanage`；缺少工具会停止配置，不擅自关闭 SELinux。
- SSH 主配置优先设置全局端口、root 登录和密码认证。常见片段中的额外全局端口会被移除。只有明确的 `Match User root` 段会调整登录开关，其他用户、组和来源地址的条件规则保留。复杂的 Include、PAM 和其他访问限制仍可能影响登录。
- 密码使用 SHA-512 哈希。旧版 OpenSSL 不支持 `passwd -6` 时依次尝试 Python 的系统 `crypt` 和 `mkpasswd`，不回退到 MD5。
- Debian / Ubuntu 的 DHCP 和同网段静态地址由安装器配置。`/32` 或离网段网关通过安装器的网络配置完成步骤设置地址、路由和 DNS，之后才选择软件源。准备阶段找不到对应步骤就停止。低内存等级由安装器判断。

## 可选功能

`--mirror URL` 保留指定仓库的 HTTP、HTTPS 或 FTP 协议。脚本逐个下载内核并解包安装环境。对 Debian / Ubuntu 的 HTTPS 源，还检查安装环境内的 HTTPS 选源组件和 GNU wget。候选源不适用时会提示并尝试备用源，备用列表含 HTTP。CentOS 6 的安装仓库沿用选中地址的协议。菜单选择国内源后回车默认使用阿里云。镜像直链的协议也会保留。

`-v x64`、`-v x86` 和 Debian 点版本参数可继续使用，例如 `-d 12.1` 选择 Debian 12 所属的 bookworm 仓库。CentOS 6 默认文本安装。选择菜单中的 VNC 或传入 `--vnc` 可远程查看安装，临时密码在重启前显示。6.4–6.10 会跳过可识别的“不受支持硬件”交互提示，驱动仍须与宿主兼容。

Debian / Ubuntu 保留旧脚本允许未认证软件包的安装器设置，以兼容旧仓库；本项目不强制 HTTPS、额外签名或镜像哈希验证。HTTP 可用不等同于镜像来源或软件包签名已验证。

`-console ttyS0,115200n8` 指定串口；不传时尽量沿用当前内核的控制台参数。`-firmware` 可为 Debian 加载固件，`--noipv6` 禁用 IPv6，`--dev-net` 使用传统网卡命名参数。

`-cmd BASE64` 为 Linux 设置首次启动命令。脚本检查 Base64 及 Bash 语法，只创建自己的 `/etc/cron.d/dd-reinstall`，首次启动尝试一次；失败保留 `/root/dd-reinstall/user-command.sh` 和 `/var/log/dd-command.log`，不自动重试，不删除其他 cron 任务。不提供复杂任务状态或恢复系统。

`--image-type rhel` 仅用于符合菜单中 RHEL 镜像约定的镜像。`--image-type windows` 保留 Windows 网络配置、可选 RDP 设置和系统卷扩容尝试：需要 NTFS 系统分区、标准 Startup 目录以及 getmac / netsh / PowerShell / DiskPart。首次管理员登录并通过提升权限后按 MAC 配置网络；扩容要求系统卷后存在可用的相邻空间，不能保证任意分区布局都能扩容。

`-rdp PORT` 沿用旧脚本的 RDP 启用、端口和 `UserAuthentication=0`（关闭 NLA）设置。没有传端口时保留镜像原来的 RDP 设置。旧式 `-dd URL -rdp PORT` 自动选择 Windows 适配。显式选择 raw 或 RHEL 后再传 `-rdp` 会报错。Windows 配置依赖首次管理员登录。

## 与修改前版本的对照

本地首次克隆记录是 `a6c73f5`，当时项目包含两个脚本入口。本版对照原文件保留扩展菜单和参数，并将网络、镜像写入、登录配置及引导修复统一到 `dd.sh`。仓库仅保留这一个可独立下载的重装脚本。

| 对照项 | 当前处理与原因 |
| --- | --- |
| 默认密码、SSH 端口、默认静态网络 | 保留 `haoduck.com`、22、静态 IPv4 |
| Debian / Ubuntu 时区 | 保留 `US/Eastern`，撤回无关的时区修改 |
| CentOS 时区和包组 | 保留 `Asia/Hong_Kong` 与 `@base`，撤回改成 `@core` 的范围变更 |
| SSH 配置 | 保留其他设置，撤回整份配置替换 |
| Windows 能力 | 对适配镜像保留网络、RDP 和系统卷扩容。预设按类型处理，自定义镜像可在菜单选择适配 |
| DHCP、密码传递、端口、配置模板 | 修复菜单选择未生效、参数拆分、脚本拼接和漏配置问题 |
| 错误处理和引导 | 关键步骤失败停止；准备完整安装文件后再切换引导；不覆盖现有内核文件 |
| 旧引导和存储布局 | 恢复 Legacy 分支，撤回对 LVM / RAID / Btrfs 的一刀切拒绝；不能安全写回标记时使用持久默认项 |
| 导出和任务系统 | 按要求删除导出，不加入复杂任务状态、断点续作或原系统恢复机制 |

**行为并非逐字等价：**导出按要求删除；DHCP 选择现在实际生效；自定义镜像不再一律尝试 Windows 注入；未适配的 Secure Boot、架构和 UEFI 组合会在修改引导前拒绝；密码格式和端口增加明确校验。这些分别属于指定删除、缺陷修复或提前失败保护。旧代码“会尝试”不等于该组合原本能成功，当前代码有对应分支也不等于已经验证成功。

## 检查范围

本次仅做静态检查。已按克隆版逐项核对预设编号与地址，并直接读取 Debian 11 amd64 官方 netboot 安装包，核实网络配置入口、HTTPS 选源组件以及写盘前需要的工具。ShellCheck 用于分析主脚本和内嵌 Shell 文本。`tests/test_dd.py` 包含回归用例，本轮没有执行项目脚本、生成脚本、函数或测试。

静态检查不能证明“没有引入任何新 bug”，也不能代替 BIOS / UEFI 启动、真实安装器、低内存条件和第三方镜像的实际验收。当前应视为已完成静态修复及对照的版本，不应描述为已完成真实 VPS 验证。

原始代码来源：MoeClub.org InstallNET、haoduck/dd、hiCasper/Shell、veip007/dd。保留 GPL 授权声明。
