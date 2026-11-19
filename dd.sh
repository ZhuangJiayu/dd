#!/bin/bash
# GPL. Based on InstallNET (MoeClub.org), haoduck/dd, hiCasper and veip007.
# Single-disk VPS reinstall. Sourcing this file never changes the host.
# Capture the entry path without launching commands. The compatibility wrapper
# uses a separate Bash so a caller's conditional cannot disable main's errexit.
case ${BASH_SOURCE[0]} in
    /*) DD_REINSTALL_SCRIPT=${BASH_SOURCE[0]} ;;
    *) DD_REINSTALL_SCRIPT=$PWD/${BASH_SOURCE[0]} ;;
esac

error() { printf '错误: %s\n' "$*" >&2; return 1; }
log() { printf '[dd] %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || error "缺少命令: $1"; }

defaults() {
    release=debian; dist=12; arch=; network_mode=static
    ip_addr=; ip_mask=; ip_gate=; ip_dns=8.8.8.8; iface=; installer_iface=; net_mac=; prefix=
    password=; password_hash=; ssh_port=22; mirror=; default_cn=n; image_url=; image_kind=raw
    image_label=; preset_arch=; preset_boot=; installer_vnc=0; vnc_password=
    console=; firmware=0; noipv6=0; legacy_names=0; rdp_port=; command_b64=
    assume_yes=0; interactive=0; workdir=; install_dir=; grub_cfg=; grub_backup=
    grub_changed=0; keep_boot=0; grub_kind=2; boot_once=1; offlink=0
}

usage() {
    cat <<'EOF'
用法: bash dd.sh                         交互菜单
      bash dd.sh -d 12 --dhcp -p '密码' -port 22
      bash dd.sh -d 13 --static --ip-addr IP --ip-mask MASK --ip-gate GW
      bash dd.sh -dd 'http://example.com/disk.raw.gz' --dhcp

  -d/--debian VERSION       Debian 10/11/12/13
  -u/--ubuntu VERSION       Ubuntu 16.04/18.04/20.04 (legacy installer)
  -c/--centos VERSION       CentOS 6.10 (amd64/i386 BIOS)
  -dd/--image URL           gzip 压缩的完整 raw 磁盘镜像
  --image-type TYPE         raw(默认)/rhel/windows；rhel 仅用于已适配镜像
  --dhcp, -a/--auto         安装环境及已适配目标系统使用 DHCP
  --static                  使用静态 IPv4；默认从当前出口接口提取
  --ip-addr IP --ip-mask MASK --ip-gate GW --ip-dns DNS
  -i/--interface NAME        安装器网卡选择；静态连接按当前出口 MAC 绑定
  -p/--password PASSWORD     默认 haoduck.com；交互输入不回显
  -port PORT                Linux SSH 端口，默认 22
  --mirror URL              安装源，保留所选 HTTP、HTTPS 或 FTP 协议
  -v/--ver ARCH             amd64/64/x64、i386/32/x86、arm64；必须与宿主兼容
  --vnc                     CentOS 6 安装期间启用 VNC，显示临时连接密码
  -console CONSOLE          如 ttyS0,115200n8
  -firmware --noipv6 --dev-net
  -rdp PORT                 Windows 适配时设置 RDP 端口
  -cmd BASE64               Linux 首次启动命令；只创建本脚本自己的 cron 文件
  -y/--yes                  跳过开始前确认
  -h/--help                 显示帮助，不修改系统

仅用于单磁盘 VPS，执行后原磁盘数据会被覆盖。不支持 OpenVZ。
--loader 导出功能已删除。通用 raw 模式不修改镜像内密码、网络或 SSH。
EOF
}

parse_args() {
    local option value explicit_kind=0
    while (($#)); do
        option=$1
        case $option in
            -d|--debian|-u|--ubuntu|-c|--centos|-dd|--image|--image-type|-p|--password|-port|-v|--ver|-i|--interface|--ip-addr|--ip-mask|--ip-gate|--ip-dns|--mirror|-apt|-yum|-console|-rdp|-cmd)
                (($# >= 2)) || { error "$option 缺少参数"; return 1; }
                value=$2
                case $option in -p|--password|-cmd) ;; *) [[ -n $value ]] || { error "$option 的参数不能为空"; return 1; } ;; esac
                case $option in
                    -d|--debian) release=debian; dist=$value ;;
                    -u|--ubuntu) release=ubuntu; dist=$value ;;
                    -c|--centos) release=centos; dist=$value ;;
                    -dd|--image) image_url=$value ;;
                    --image-type) image_kind=$value; explicit_kind=1 ;;
                    -p|--password) password=$value ;;
                    -port) ssh_port=$value ;;
                    -v|--ver) arch=$value ;;
                    -i|--interface) installer_iface=$value ;;
                    --ip-addr) ip_addr=$value ;;
                    --ip-mask) ip_mask=$value ;;
                    --ip-gate) ip_gate=$value ;;
                    --ip-dns) ip_dns=$value ;;
                    --mirror|-apt|-yum) mirror=$value ;;
                    -console) console=$value ;;
                    -rdp) rdp_port=$value ;;
                    -cmd) command_b64=$value ;;
                esac
                shift 2 ;;
            --dhcp|-a|--auto) network_mode=dhcp; shift ;;
            --static) network_mode=static; shift ;;
            --vnc) installer_vnc=1; shift ;;
            -firmware) firmware=1; shift ;;
            --noipv6) noipv6=1; shift ;;
            --dev-net) legacy_names=1; shift ;;
            -m|--manual|-ssl) shift ;; # Compatibility: these were no-ops in the original.
            -y|--yes) assume_yes=1; shift ;;
            -h|--help) usage; return 2 ;;
            --loader) error '导出功能 --loader 已删除'; return 1 ;;
            *) error "未知参数: $option"; return 1 ;;
        esac
    done
    if [[ -n $rdp_port && -n $image_url && $explicit_kind == 0 ]]; then image_kind=windows; fi
}

valid_ipv4() {
    local part parts
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local IFS=.
    read -r -a parts <<< "$1"
    for part in "${parts[@]}"; do
        [[ ${#part} -le 3 ]] && ((10#$part <= 255)) || return 1
        [[ $part == 0 || $part != 0* ]] || return 1
    done
}

ipv4_number() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    printf '%s\n' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

mask_prefix() {
    valid_ipv4 "$1" || return 1
    local mask bit count=0 zero=0
    mask=$(ipv4_number "$1")
    for ((bit=31; bit>=0; bit--)); do
        if (( (mask >> bit) & 1 )); then
            ((zero == 0)) || return 1
            count=$((count + 1))
        else zero=1
        fi
    done
    printf '%s\n' "$count"
}

prefix_mask() {
    [[ $1 =~ ^[0-9]{1,2}$ ]] && ((10#$1 <= 32)) || return 1
    local value=$(( (0xffffffff << (32 - 10#$1)) & 0xffffffff ))
    printf '%s.%s.%s.%s\n' "$(((value >> 24) & 255))" "$(((value >> 16) & 255))" "$(((value >> 8) & 255))" "$((value & 255))"
}

normalize_port() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] || return 1
    local number=$((10#$1))
    ((number >= 1 && number <= 65535)) || return 1
    printf '%s\n' "$number"
}

valid_url() {
    [[ $1 =~ ^(https?|ftp)://[^/[:space:]]+(/[^[:space:]]*)?$ && $1 != *[[:cntrl:]]* ]]
}

normalize_options() {
    local host_arch dns LC_ALL=C
    password=${password:-haoduck.com}
    [[ $password != *$'\n'* && $password != *$'\r'* && ${#password} -le 128 ]] || {
        error '密码不得含换行，且最多 128 字节'; return 1;
    }
    ssh_port=$(normalize_port "$ssh_port") || { error 'SSH 端口必须为 1–65535'; return 1; }
    if [[ -n $rdp_port ]]; then
        rdp_port=$(normalize_port "$rdp_port") || { error 'RDP 端口无效'; return 1; }
        [[ $image_kind == windows && -n $image_url ]] || { error '-rdp 仅用于 Windows 镜像适配'; return 1; }
    fi
    case $image_kind in raw|rhel|windows) ;; *) error '未知镜像类型'; return 1 ;; esac
    [[ -z $image_url ]] || valid_url "$image_url" || { error '镜像 URL 无效'; return 1; }
    [[ -z $mirror ]] || valid_url "$mirror" || { error '安装源 URL 无效'; return 1; }
    mirror=${mirror%/}
    [[ -z $console || $console =~ ^[a-zA-Z0-9,._=-]+$ ]] || { error '控制台参数无效'; return 1; }
    [[ -z $installer_iface || $installer_iface =~ ^[a-zA-Z0-9_.:-]+$ ]] || { error '安装器网卡名无效'; return 1; }
    [[ $ip_dns != *$'\n'* && $ip_dns != *$'\r'* ]] || { error 'DNS 不得包含换行'; return 1; }
    if [[ $network_mode == dhcp && ( -n $ip_addr || -n $ip_mask || -n $ip_gate ) ]]; then
        error 'DHCP 模式不能同时指定静态地址、掩码或网关'; return 1
    fi
    for dns in $ip_dns; do valid_ipv4 "$dns" || { error 'DNS 必须为 IPv4 地址（多个地址用空格分隔）'; return 1; }; done
    [[ -n $ip_dns ]] || { error 'DNS 不能为空'; return 1; }
    case $(uname -m) in x86_64|amd64) host_arch=amd64 ;; x86|i?86) host_arch=i386 ;; aarch64|arm64) host_arch=arm64 ;; *) error '不支持宿主架构'; return 1 ;; esac
    arch=$(printf '%s' "${arch:-$host_arch}" | tr '[:upper:]' '[:lower:]') || return 1
    case $arch in 64|x64|amd64|x86_64) arch=amd64 ;; 32|x86|i386|i686) arch=i386 ;; arm64|aarch64) arch=arm64 ;; *) error '架构无效'; return 1 ;; esac
    [[ $arch == "$host_arch" || ( $host_arch == amd64 && $arch == i386 ) ]] || { error '安装架构与宿主不兼容'; return 1; }
    case $preset_arch:$host_arch in :*|amd64:amd64|i386:amd64|i386:i386|x86:amd64|x86:i386) ;; *) error '历史预设镜像与宿主架构不兼容'; return 1 ;; esac
    if [[ -n $image_url ]]; then
        [[ $image_kind != rhel || $arch == amd64 ]] || { error '已适配 RHEL 镜像仅支持 amd64'; return 1; }
        release=debian; dist=bullseye
    else
        [[ $image_kind == raw && -z $rdp_port ]] || { error '镜像类型需要 -dd URL'; return 1; }
        dist=$(printf '%s' "$dist" | tr '[:upper:]' '[:lower:]') || return 1
        if [[ $release == debian && $dist =~ ^([0-9]+)(\.[0-9]+)+$ ]]; then dist=${BASH_REMATCH[1]}; fi
        case $release:$dist in
            debian:7|debian:wheezy) dist=wheezy ;; debian:8|debian:jessie) dist=jessie ;;
            debian:9|debian:stretch) dist=stretch ;;
            debian:10|debian:buster) dist=buster ;; debian:11|debian:bullseye) dist=bullseye ;;
            debian:12|debian:bookworm) dist=bookworm ;; debian:13|debian:trixie) dist=trixie ;;
            ubuntu:12.04|ubuntu:precise) dist=precise ;; ubuntu:14.04|ubuntu:trusty) dist=trusty ;;
            ubuntu:16.04|ubuntu:xenial) dist=xenial ;; ubuntu:18.04|ubuntu:bionic) dist=bionic ;;
            ubuntu:20.04|ubuntu:focal) dist=focal ;; centos:6) dist=6.10 ;;
            centos:6.[0-9]|centos:6.10) ;; # Keep original 6.x command-line versions.
            *) error '发行版或版本不在支持列表中'; return 1 ;;
        esac
        [[ $release != centos || $arch == amd64 || $arch == i386 ]] || { error 'CentOS 6 仅支持 amd64/i386'; return 1; }
    fi
    [[ -z $image_url || $image_kind != raw || -z $command_b64 ]] || { error '通用 raw 模式不支持 -cmd'; return 1; }
    [[ $image_kind != windows || -z $command_b64 ]] || { error 'Windows 模式不支持 Linux 首次启动命令'; return 1; }
    ((installer_vnc == 0)) || [[ $release == centos && -z $image_url ]] || { error '--vnc 仅用于 CentOS 6 网络安装'; return 1; }
}

detect_cn_default() {
    local geo=''
    if command -v curl >/dev/null 2>&1; then
        geo=$(curl -fskSL --connect-timeout 3 --max-time 5 http://ipinfo.io/json) ||
            geo=$(curl -fskSL --connect-timeout 3 --max-time 5 -A Mozilla http://api.ip.sb/geoip) || geo=''
    fi
    if printf '%s' "$geo" | grep -Eq '"country"[[:space:]]*:[[:space:]]*"CN"'; then printf y
    else printf n
    fi
}

choose_mirror() {
    local answer choice
    IFS= read -r -p "使用国内安装源？[默认 $default_cn]: " answer || return 1
    answer=${answer:-$default_cn}
    case $answer in y|Y|yes|YES) ;; *) return 0 ;; esac
    while :; do
        printf '%s\n' '1) 阿里云（默认） 2) 腾讯 3) 网易 4) 华为 5) 清华 6) 中科大 7) 腾讯内网 99) 自定义'
        IFS= read -r -p '选择源 [1]: ' choice || return 1
        case ${choice:-1} in
            1) mirror=http://mirrors.aliyun.com ;; 2) mirror=http://mirrors.tencent.com ;;
            3) mirror=http://mirrors.163.com ;; 4) mirror=http://mirrors.huaweicloud.com ;;
            5) mirror=http://mirrors.tuna.tsinghua.edu.cn ;; 6) mirror=http://mirrors.ustc.edu.cn ;;
            7) mirror=http://mirrors.tencentyun.com ;;
            99) IFS= read -r -p '镜像站地址: ' mirror || return 1; [[ $mirror == *://* ]] || mirror=http://$mirror ;;
            *) log '编号无效'; continue ;;
        esac
        valid_url "$mirror" && break
        log '地址无效'
    done
    case $release in debian) mirror=${mirror%/}/debian ;; ubuntu) mirror=${mirror%/}/ubuntu ;; centos) mirror=${mirror%/}/centos-vault ;; esac
}

image_presets() {
    # Number, original label, CPU, required firmware, adaptation, URL, image login.
    cat <<'PRESETS'
9|CentOS 7.8|amd64|bios|rhel|https://api.moetools.net/get/centos-78-image|
10|CentOS 7.6|amd64|bios|rhel|https://api.moetools.net/get/centos-76-image|
11|Rocky Linux 8.6|amd64|bios|rhel|https://api.moetools.net/get/rocky-8-image|
12|萌咖Win7x64|amd64|any|windows|https://www.lefu.men/gdzl/?id=1qhE4hHkCAgAiRby8WHngNduHHhqrUeMQ|用户名:Administrator  密码：Vicer
13|Win2019 By:MeowLove|amd64|any|windows|https://www.lefu.men/gdzl/?id=1IXdK-ruDrNmorxZRoJaep1Fo9p4aPi0s|密码：cxthhhhh.com
14|Win2016 By:MeowLove|amd64|any|windows|https://www.lefu.men/gdzl/?id=1JnbvgbvF4hzT1msk1RJ-rjrzqqzTwI1I|密码：cxthhhhh.com
15|Win2012 R2 By:MeowLove|amd64|any|windows|https://www.lefu.men/gdzl/?id=1vz2Y9kPlbRYdP8blD0oGs5MY7EfYVgFR|密码：cxthhhhh.com
16|Win2008 R2 By:MeowLove|amd64|any|windows|https://www.lefu.men/gdzl/?id=1dvNvV9OLm-x6p9sUbnRrKTLDuaiVj_Kg|密码：cxthhhhh.com
17|Windows 7 Vienna By:MeowLove|x86|any|windows|https://www.lefu.men/gdzl/?id=1O3jXs9KagrCb1SbM-DVZMAZ7gw9r3Vtp|密码：cxthhhhh.com
18|Windows 2003 Vienna By:MeowLove|x86|any|raw|https://www.lefu.men/gdzl/?id=1PLG3EdCziMMTIWz1vnUupMPmje2pQX43|密码：cxthhhhh.com
19|Win7x32 By:老司机|i386|any|windows|https://www.lefu.men/gdzl/?id=16Xh4iq6guHWT92MAr-NCOzStZqMTdnmU|用户名:Administrator  密码：Windows7x86-Chinese
20|Win-2003x32 By:老司机|i386|any|raw|https://drive.google.com/open?id=1rzkH24tCtwPvcT3HquoF9tZgcj022voG|用户名:Administrator  密码：WinSrv2003x86-Chinese
21|Win2008x64 By:老司机|amd64|any|windows|https://www.lefu.men/gdzl/?id=1wtUWaag5pVwmN-QUfTSJ6xbNWulLbLy-|用户名:Administrator  密码：WinSrv2008x64-Chinese
22|Win2012R2x64 By:老司机|amd64|any|windows|https://www.lefu.men/gdzl/?id=1GUdLXMwBx4uM8-iBU6ClcD5HRmkURuEl|用户名:Administrator  密码：WinSrv2012r2
23|CentOS 8|amd64|bios|rhel|https://odc.cxthhhhh.com/d/SyStem/CentOS/CentOS_8.X_x64_Legacy_NetInstallation_Stable_v6.8.vhd.gz|
24|Win7x64 By:net.nn|amd64|any|windows|https://www.lefu.men/gdzl/?id=1fGsryTy6xZi5EC9GlOpvqTK-Uty0_gFo|用户名:Administrator  密码：nat.ee
25|Win7x64 Uefi启动的VPS专用(如:甲骨文)By:net.nn|amd64|uefi|windows|https://www.lefu.men/gdzl/?id=1LxzyhswxkpI_BqUolnI0HyawNvPQJHAO|用户名:Administrator  密码：nat.ee
26|Win8.1x64 By:net.nn|amd64|any|windows|https://www.lefu.men/gdzl/?id=1SKUFoUujxh3sTtLIWWcBW8riibd1q5ka|用户名:Administrator  密码：nat.ee
27|Win8.1x64 Uefi启动的VPS专用(如:甲骨文)By:net.nn|amd64|uefi|windows|https://www.lefu.men/gdzl/?id=1GUz7Suysv0S7qRuyB9vQ_IGkTbFckFcE|用户名:Administrator  密码：nat.ee
28|2008r2x64 By:net.nn|amd64|any|windows|https://www.lefu.men/gdzl/?id=1eA35gszGgUXI6P7dR5g5sqsIPnMJwUuN|用户名:Administrator  密码：nat.ee
29|2008r2x64 Uefi启动的VPS专用(如:甲骨文)By:net.nn|amd64|uefi|windows|https://www.lefu.men/gdzl/?id=1a8gEiZTEG5aeTrTflP9icAZF-HJhYU1N|用户名:Administrator  密码：nat.ee
30|Win8.1x64 By:net.nn|amd64|any|windows|https://www.lefu.men/gdzl/?id=1eboWyVSkt1Hcnsl2dqgA-8p40Qbk2QvG|用户名:Administrator  密码：nat.ee
31|Win8.1x64 Uefi启动的VPS专用(如:甲骨文)By:net.nn|amd64|uefi|windows|https://www.lefu.men/gdzl/?id=1IY8IyLt66uKhZ7Jb4QzEb_bTUUqU76_3|用户名:Administrator  密码：nat.ee
32|win10-ltsc-x64-cn|amd64|any|windows|https://haoduck.com/files/dd/laosiji/win10-ltsc-x64-cn.vhd.gz|Username:Administrator  Password：nat.ee
33|win7-ent-sp1-x64-cn|amd64|any|windows|https://haoduck.com/files/dd/laosiji/win7-ent-sp1-x64-cn.vhd.gz|Username:Administrator  Password：nat.ee
34|win8.1-ent-x64-cn|amd64|any|windows|https://haoduck.com/files/dd/laosiji/win8.1-ent-x64-cn.vhd.gz|Username:Administrator  Password：nat.ee
35|winsrv2008r2-data-sp1-x64-cn|amd64|any|windows|https://haoduck.com/files/dd/laosiji/winsrv2008r2-data-sp1-x64-cn.vhd.gz|Username:Administrator  Password：nat.ee
36|winsrv2012r2-data-x64-cn|amd64|any|windows|https://haoduck.com/files/dd/laosiji/winsrv2012r2-data-x64-cn.vhd.gz|Username:Administrator  Password：nat.ee
PRESETS
}

choose_preset() {
    local number label cpu boot kind url login
    while IFS='|' read -r number label cpu boot kind url login; do
        [[ $number == "$1" ]] || continue
        image_label="$number) $label"; image_url=$url; image_kind=$kind
        preset_arch=$cpu; preset_boot=$boot
        [[ -z $login ]] || printf '镜像原始登录信息：%s\n' "$login"
        return 0
    done < <(image_presets)
    return 1
}

menu() {
    local choice answer
    cat <<'EOF'
1) Debian 13     2) Debian 12     3) Debian 11     4) Debian 10
5) Ubuntu 20.04  6) Ubuntu 18.04  7) Ubuntu 16.04  8) CentOS 6.10
以下为镜像覆盖：
9) CentOS 7.8   10) CentOS 7.6   11) Rocky Linux 8.6
99) 查看历史镜像（12–36）    100) 自定义 raw.gz 直链
EOF
    while :; do
        IFS= read -r -p '输入编号: ' choice || return 1
        case $choice in
            1) dist=13 ;; 2) dist=12 ;; 3) dist=11 ;; 4) dist=10 ;;
            5) release=ubuntu; dist=20.04 ;; 6) release=ubuntu; dist=18.04 ;; 7) release=ubuntu; dist=16.04 ;;
            8) release=centos; dist=6.10 ;;
            99) image_presets | awk -F '|' '$1 >= 12 {print $1 ") " $2}'; continue ;;
            9|1[0-9]|2[0-9]|3[0-6]) choose_preset "$choice" || return 1 ;;
            100)
                IFS= read -r -p 'raw.gz URL: ' image_url || return 1
                valid_url "$image_url" || { error '镜像 URL 无效'; return 1; }
                while :; do
                    IFS= read -r -p '1) 仅写盘（默认） 2) Windows 网络/RDP/扩容适配: ' answer || return 1
                    case ${answer:-1} in 1) image_kind=raw; break ;; 2) image_kind=windows; break ;; *) log '编号无效' ;; esac
                done
                ;;
            *) log '编号无效'; continue ;;
        esac
        break
    done
    [[ -z $image_url ]] || release=debian
    if [[ $image_kind == windows ]]; then IFS= read -r -p 'RDP 端口（回车保留镜像设置）: ' rdp_port || return 1; fi
    if [[ $release == centos ]]; then
        IFS= read -r -p '安装期间启用 VNC 查看进度？[y/N]: ' answer || return 1
        case $answer in y|Y|yes|YES) installer_vnc=1 ;; esac
    fi
    default_cn=$(detect_cn_default)
    choose_mirror || return 1
    if [[ -z $image_url || $image_kind == rhel ]]; then
        IFS= read -r -s -p 'Root 密码 [haoduck.com]: ' password || return 1
        printf '\n'
        IFS= read -r -p 'SSH 端口 [22]: ' ssh_port || return 1
        ssh_port=${ssh_port:-22}
    fi
    IFS= read -r -p '使用 DHCP？[y/N，默认静态]: ' answer || return 1
    case $answer in y|Y|yes|YES) network_mode=dhcp ;; *) network_mode=static ;; esac
}

install_dependencies() {
    local missing=0 bin
    for bin in ip wget curl file xz cpio gzip lsblk blkid openssl flock base64; do
        command -v "$bin" >/dev/null 2>&1 || missing=1
    done
    if ((missing)); then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y iproute2 wget curl file xz-utils cpio gzip util-linux openssl coreutils || return 1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y iproute wget curl file xz cpio gzip util-linux openssl coreutils || return 1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y iproute wget curl file xz cpio gzip util-linux openssl coreutils || return 1
        else error '请先安装所需命令'; return 1
        fi
    fi
    for bin in ip wget curl file xz cpio gzip lsblk blkid openssl flock base64 awk sed find readlink; do need "$bin" || return 1; done
}

detect_network() {
    local route token previous='' src='' route_iface='' route_gate='' cidr='' line
    route=$(ip -4 route get 1.1.1.1) || { error '无法探测 IPv4 出口路由'; return 1; }
    for token in $route; do
        case $previous in dev) route_iface=$token ;; src) src=$token ;; via) route_gate=$token ;; esac
        previous=$token
    done
    iface=${iface:-$route_iface}
    [[ -n $iface && $iface =~ ^[a-zA-Z0-9_.:-]+$ ]] || { error '无法确定出口接口'; return 1; }
    if [[ $iface != "$route_iface" ]]; then
        error '指定接口必须与当前默认出口一致'; return 1
    fi
    net_mac=$(cat "/sys/class/net/$iface/address") || return 1
    [[ $net_mac =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || { error '无法获取网卡 MAC'; return 1; }
    [[ $network_mode == static ]] || return 0
    while IFS= read -r line; do
        cidr=$(awk '{print $4}' <<< "$line")
        [[ ${cidr%/*} == "$src" ]] && break
        cidr=
    done < <(ip -o -4 addr show dev "$iface" scope global)
    ip_addr=${ip_addr:-${cidr%/*}}
    if [[ -z $ip_mask && -n $cidr ]]; then ip_mask=$(prefix_mask "${cidr#*/}") || return 1; fi
    ip_gate=${ip_gate:-$route_gate}
    # Keep /32 and off-subnet gateways; a host route will make the gateway reachable.
    if ((interactive)); then
        while :; do
            printf 'IP=%s  MASK=%s  GW=%s  DNS=%s\n' "$ip_addr" "$ip_mask" "$ip_gate" "$ip_dns"
            IFS= read -r -p '网络信息正确？[Y/n]: ' token || return 1
            case $token in n|N|no|NO)
                IFS= read -r -p "IP [$ip_addr]: " token || return 1; ip_addr=${token:-$ip_addr}
                IFS= read -r -p "掩码 [$ip_mask]: " token || return 1; ip_mask=${token:-$ip_mask}
                IFS= read -r -p "网关 [$ip_gate]: " token || return 1; ip_gate=${token:-$ip_gate}
                IFS= read -r -p "DNS [$ip_dns]: " token || return 1; ip_dns=${token:-$ip_dns} ;;
                *) break ;;
            esac
        done
    fi
    validate_network
}

validate_network() {
    local addr gate mask dns
    if ! valid_ipv4 "$ip_addr" || ! valid_ipv4 "$ip_gate"; then error '静态 IP 或网关无效'; return 1; fi
    prefix=$(mask_prefix "$ip_mask") || { error '子网掩码无效或不连续'; return 1; }
    ((prefix > 0)) || { error '不支持 /0 地址前缀'; return 1; }
    for dns in $ip_dns; do valid_ipv4 "$dns" || { error 'DNS 无效'; return 1; }; done
    [[ -n $ip_dns ]] || { error 'DNS 不能为空'; return 1; }
    addr=$(ipv4_number "$ip_addr"); gate=$(ipv4_number "$ip_gate"); mask=$(ipv4_number "$ip_mask")
    offlink=0
    (( (addr & mask) == (gate & mask) )) || offlink=1
    if [[ $release == centos && $offlink == 1 ]]; then
        error 'CentOS 6 网络安装不支持离网段网关；请使用 DHCP 或其他系统'; return 1
    fi
}

get_disk() {
    local disk
    disk=$(lsblk -dn -o NAME,TYPE | awk '$2 == "disk" {print "/dev/" $1; exit}') || return 1
    [[ -n $disk && -b $disk ]] || { error '未找到可用磁盘'; return 1; }
    printf '%s\n' "$disk"
}

make_password_hash() {
    local hash='' python_cmd
    if hash=$(printf '%s\n' "$password" | openssl passwd -6 -stdin 2>/dev/null); then :
    else
        # CentOS 6/7 ship OpenSSL without passwd -6, but their Python/glibc
        # crypt implementation supports SHA-512. Preserve literal input on stdin.
        for python_cmd in python3 python2 python; do
            command -v "$python_cmd" >/dev/null 2>&1 || continue
            # Keep Python's literal "$6$" crypt identifiers out of Shell expansion.
            # shellcheck disable=SC2016
            if hash=$(printf '%s\n' "$password" | "$python_cmd" -c '
import base64, crypt, os, sys
secret = getattr(sys.stdin, "buffer", sys.stdin).read()[:-1]
if not isinstance(secret, str):
    secret = secret.decode("utf-8")
salt = base64.b64encode(os.urandom(12)).decode("ascii").replace("+", ".")
result = crypt.crypt(secret, "$6$" + salt + "$")
if not result or not result.startswith("$6$"):
    sys.exit(1)
sys.stdout.write(result + "\n")
' 2>/dev/null); then break; fi
        done
        if [[ -z $hash ]] && command -v mkpasswd >/dev/null 2>&1; then
            hash=$(printf '%s\n' "$password" | mkpasswd -m sha-512 -s) || return 1
        fi
    fi
    [[ $hash =~ ^\$6\$(rounds=[0-9]+\$)?[./a-zA-Z0-9]+\$[./a-zA-Z0-9]{86}$ ]] || { error '密码哈希生成失败'; return 1; }
    password_hash=$hash
    password=
}

download() {
    local url=$1 dest=$2
    wget --no-check-certificate --timeout=30 --tries=2 -q -O "$dest" "$url" && [[ -s $dest ]] || {
        error "下载失败: $url"; return 1;
    }
}

installer_paths() {
    local base centos_arch=x86_64
    if [[ $release == centos ]]; then
        [[ $arch != i386 ]] || centos_arch=i386
        kernel_path="$dist/os/$centos_arch/isolinux/vmlinuz"
        initrd_path="$dist/os/$centos_arch/isolinux/initrd.img"
    else
        [[ $dist == focal ]] && base=legacy-images || base=images
        kernel_path="dists/$dist/main/installer-$arch/current/$base/netboot/$release-installer/$arch/linux"
        initrd_path="${kernel_path%/linux}/initrd.gz"
    fi
}

installer_supports_https() {
    [[ $release != centos ]] || return 0
    local root=$workdir/root program
    # choose-mirror only offers HTTPS when built with it and GNU wget is present.
    grep -Fxq 'Package: wget-udeb' "$root/var/lib/dpkg/status" || return 1
    for program in "$root/bin/choose-mirror" "$root/usr/bin/choose-mirror" "$root/var/lib/dpkg/info/choose-mirror-bin.postinst"; do
        [[ -f $program ]] || continue
        LC_ALL=C grep -aFq 'mirror/https/hostname' "$program" && return 0
    done
    return 1
}

fetch_installer() {
    local candidate candidates=()
    installer_paths
    [[ -z $mirror ]] || candidates+=("$mirror")
    case $release in
        debian) candidates+=(http://deb.debian.org/debian http://archive.debian.org/debian) ;;
        ubuntu) if [[ $arch == arm64 ]]; then candidates+=(http://ports.ubuntu.com/ubuntu-ports http://old-releases.ubuntu.com/ubuntu); else candidates+=(http://archive.ubuntu.com/ubuntu http://old-releases.ubuntu.com/ubuntu); fi ;;
        centos) candidates+=(http://vault.centos.org) ;;
    esac
    for candidate in "${candidates[@]}"; do
        log "尝试安装源: $candidate"
        if download "$candidate/$initrd_path" "$workdir/initrd.original" && download "$candidate/$kernel_path" "$workdir/vmlinuz"; then
            file "$workdir/vmlinuz" | grep -Eiq 'kernel|boot executable|PE32|ARM.*executable' || { log '下载的内核格式无效'; continue; }
            # Do not carry files from a failed candidate into another initrd.
            rm -rf -- "${workdir:?}/root" || return 1
            unpack_initrd || { log '安装环境无效，尝试下一安装源'; continue; }
            if [[ $candidate == https://* ]] && ! installer_supports_https; then
                log '此安装环境缺少 HTTPS 仓库组件，尝试下一安装源'
                continue
            fi
            selected_mirror=$candidate
            return 0
        fi
    done
    error '所有安装源均不可用（内核和 initrd 必须同时可下载）'
}

unpack_initrd() {
    local kind
    mkdir -p "$workdir/root" || return 1
    kind=$(file -b "$workdir/initrd.original") || return 1
    case $kind in
        *gzip*) gzip -dc "$workdir/initrd.original" > "$workdir/initrd.cpio" || return 1 ;;
        *XZ*) xz -dc "$workdir/initrd.original" > "$workdir/initrd.cpio" || return 1 ;;
        *LZMA*) xz --format=lzma -dc "$workdir/initrd.original" > "$workdir/initrd.cpio" || return 1 ;;
        *) error '不支持的 initrd 压缩格式'; return 1 ;;
    esac
    (cd "$workdir/root" && cpio -idm --no-absolute-filenames < "$workdir/initrd.cpio") > "$workdir/unpack.log" 2>&1 || {
        tail -n 20 "$workdir/unpack.log" >&2; error 'initrd 解包失败'; return 1;
    }
    [[ -f $workdir/root/init ]] || { error 'initrd 缺少 init'; return 1; }
    rm -f "$workdir/initrd.cpio"
}

prepare_initrd() {
    if ((firmware)); then
        [[ $release == debian ]] || { error '-firmware 仅支持 Debian'; return 1; }
        download "http://cdimage.debian.org/cdimage/unofficial/non-free/firmware/$dist/current/firmware.cpio.gz" "$workdir/firmware.gz" || return 1
        (set -o pipefail; cd "$workdir/root" && gzip -dc "$workdir/firmware.gz" | cpio -idm --no-absolute-filenames) > "$workdir/firmware.log" 2>&1 || return 1
    fi
    mkdir -p "$workdir/root/dd"
}

# Payloads use POSIX sh: the Debian installer does not need Bash or pipefail.
write_payloads() {
    local dir=$workdir/root/dd key value
    for key in network_mode ip_addr ip_mask ip_gate ip_dns prefix net_mac iface ssh_port password_hash image_kind rdp_port offlink; do
        value=${!key}
        printf '%s\n' "$value" > "$dir/$key" || return 1
    done
    printf '%s\n' "$image_url" > "$dir/image_url"
    if [[ -n $command_b64 ]]; then
        printf '%s' "$command_b64" | base64 -d > "$dir/user-command.sh" || { error '-cmd 不是合法 Base64'; return 1; }
        bash -n "$dir/user-command.sh" || { error '-cmd 解码后的 Bash 脚本语法无效'; return 1; }
    fi
    cat > "$dir/network.sh" <<'PAYLOAD'
#!/bin/sh
set -eu
data=${1:-/dd}
read_value() { IFS= read -r value < "$data/$1"; }
read_value network_mode
[ "$value" = static ] || exit 0
read_value net_mac; mac=$value
device=
# Allow udev/module probing to finish before looking for the MAC-bound device.
for module in virtio_net xen_netfront hv_netvsc e1000 e1000e vmxnet3; do modprobe "$module" 2>/dev/null || true; done
attempt=0
while [ -z "$device" ] && [ "$attempt" -lt 30 ]; do
    for path in /sys/class/net/*; do
        [ -r "$path/address" ] || continue
        IFS= read -r found < "$path/address"
        if [ "$found" = "$mac" ]; then device=${path##*/}; break; fi
    done
    attempt=$((attempt + 1))
    [ -n "$device" ] || sleep 1
done
[ -n "$device" ] || { echo '找不到出口网卡' >&2; exit 1; }
read_value ip_addr; address=$value
read_value prefix; prefix=$value
read_value ip_gate; gateway=$value
ip link set dev "$device" up
if ! ip addr show dev "$device" | grep -F "inet $address/$prefix " >/dev/null; then
    ip addr add "$address/$prefix" dev "$device"
fi
has_route() {
    while IFS= read -r route; do
        for expected in "$@"; do
            case "$route " in "$expected "*) return 0 ;; esac
        done
    done
    return 1
}
if ! ip route show "$gateway/32" | has_route "$gateway dev $device" "$gateway/32 dev $device"; then
    ip route add "$gateway/32" dev "$device"
fi
if ! ip route show default | has_route "default via $gateway dev $device"; then
    ip route add default via "$gateway" dev "$device"
fi
read_value ip_dns
: > /etc/resolv.conf
for dns in $value; do printf 'nameserver %s\n' "$dns" >> /etc/resolv.conf; done
PAYLOAD
    cat > "$dir/configure.sh" <<'PAYLOAD'
#!/bin/sh
# Run inside the target (via in-target/chroot), never source credential files.
set -eu
umask 077
data=${1:-/root/dd-reinstall}
read_value() { IFS= read -r value < "$data/$1"; }

write_ssh_config() {
    root=$1; port=$2
    [ ! -f "$root/etc/ssh/sshd_config" ] || [ -f "$root/etc/ssh/sshd_config.before-dd" ] ||
        cp -p "$root/etc/ssh/sshd_config" "$root/etc/ssh/sshd_config.before-dd"
    # The leading global settings take precedence. Port is cumulative, so it
    # also needs removal from global sections of conventional drop-ins.
    for fragment in "$root/etc/ssh/sshd_config.d/"*.conf; do
        [ -f "$fragment" ] || continue
        [ -f "$fragment.before-dd" ] || cp -p "$fragment" "$fragment.before-dd"
        rewrite_ssh_settings "$fragment" > "$fragment.dd-new"
        if cmp -s "$fragment" "$fragment.dd-new"; then rm -f "$fragment.dd-new"
        else mv "$fragment.dd-new" "$fragment"; fi
    done
    {
        printf '# dd.sh managed login settings; original: sshd_config.before-dd\n'
        printf 'Port %s\nPermitRootLogin yes\nPasswordAuthentication yes\n' "$port"
        rewrite_ssh_settings "$root/etc/ssh/sshd_config"
    } > "$root/etc/ssh/sshd_config.dd-new"
}

rewrite_ssh_settings() {
    awk '
        {
            line=$0
            sub(/^[ \t]+/, "", line); sub(/[ \t]+#.*/, "", line); sub(/[ \t]+$/, "", line)
            keyword=line; sub(/[ \t=].*/, "", keyword); keyword=tolower(keyword)
            args=line; sub(/^[^ \t=]+[ \t=]*/, "", args)
        }
        keyword == "match" {
            conditional=1
            n=split(args, criteria, /[ \t]+/)
            root_only=(n == 2 && tolower(criteria[1]) == "user" && criteria[2] == "root")
        }
        !conditional && keyword == "port" {next}
        root_only && keyword == "permitrootlogin" {print "    PermitRootLogin yes"; next}
        root_only && keyword == "passwordauthentication" {print "    PasswordAuthentication yes"; next}
        {print}
    ' "$1"
}

write_iptables_rule() {
    rules=$1; port=$2
    # iptables-save may contain raw/nat tables before filter. Never insert INPUT there.
    if ! awk -v port="$port" '
        /^\*filter$/ {filter=1; input=0}
        filter && /^:INPUT / {input=1}
        filter && input && !done && (/^-A / || /^COMMIT$/) {
            print "-A INPUT -p tcp --dport " port " -j ACCEPT"; done=1
        }
        {print}
        /^COMMIT$/ {filter=0}
        END {if (!done) exit 1}
    ' "$rules" > "$rules.dd-new"; then
        rm -f "$rules.dd-new"
        echo '无法在 filter 表中设置 SSH 端口' >&2
        return 1
    fi
    mv "$rules.dd-new" "$rules"
}

configure_network() {
    root=$1; family=$2
    read_value net_mac; mac=$value
    read_value network_mode; mode=$value
    read_value iface; old_iface=$value
    # Debian DHCP is already generated by netcfg. Static and RHEL use a MAC-bound name.
    if [ "$family" != rhel ] && [ "$mode" = dhcp ]; then return 0; fi
    mkdir -p "$root/etc/udev/rules.d"
    printf 'SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="%s", NAME="ddnet0"\n' "$mac" > "$root/etc/udev/rules.d/70-dd-net.rules"
    read_value ip_addr; address=$value
    read_value ip_mask; mask=$value
    read_value prefix; bits=$value
    read_value ip_gate; gateway=$value
    read_value ip_dns; dns=$value
    if [ "$family" = rhel ]; then
        scripts=$root/etc/sysconfig/network-scripts
        [ -d "$scripts" ] || { echo '镜像缺少 network-scripts 配置目录' >&2; return 1; }
        mkdir -p "$scripts/dd-backup"
        for profile in "$scripts"/ifcfg-*; do
            [ -f "$profile" ] || continue
            case ${profile##*/} in ifcfg-lo|ifcfg-ddnet0) continue ;; esac
            if [ "${profile##*/}" = ifcfg-eth0 ] || [ "${profile##*/}" = "ifcfg-$old_iface" ] || grep -iq "$mac" "$profile"; then
                mv "$profile" "$scripts/dd-backup/"
                route=$scripts/route-${profile##*/ifcfg-}
                [ ! -f "$route" ] || mv "$route" "$scripts/dd-backup/"
            fi
        done
        {
            printf 'TYPE=Ethernet\nNAME=ddnet0\nDEVICE=ddnet0\nHWADDR=%s\nONBOOT=yes\nZONE=public\n' "$mac"
            if [ "$mode" = dhcp ]; then printf 'BOOTPROTO=dhcp\n'
            else
                printf 'BOOTPROTO=none\nIPADDR=%s\nPREFIX=%s\n' "$address" "$bits"
                index=1
                for server in $dns; do printf 'DNS%s=%s\n' "$index" "$server"; index=$((index + 1)); done
            fi
        } > "$scripts/ifcfg-ddnet0"
        if [ "$mode" = static ]; then
            printf '%s/32 dev ddnet0\ndefault via %s dev ddnet0\n' "$gateway" "$gateway" > "$scripts/route-ddnet0"
        else rm -f "$scripts/route-ddnet0"
        fi
    else
        mkdir -p "$root/etc/network"
        # Install ifupdown explicitly; do not leave two managers configuring the same NIC.
        if [ -d "$root/etc/netplan" ]; then
            mkdir -p "$root/etc/netplan/before-dd"
            for yaml in "$root/etc/netplan/"*.yaml; do [ ! -f "$yaml" ] || mv "$yaml" "$root/etc/netplan/before-dd/"; done
        fi
        {
            printf 'auto lo\niface lo inet loopback\n\nauto ddnet0\niface ddnet0 inet static\n'
            printf '    address %s\n    netmask %s\n' "$address" "$mask"
            printf '    up ip route replace %s/32 dev ddnet0\n' "$gateway"
            printf '    up ip route replace default via %s dev ddnet0\n' "$gateway"
            printf '    dns-nameservers %s\n' "$dns"
        } > "$root/etc/network/interfaces"
        mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
        if [ -f "$root/lib/systemd/system/networking.service" ]; then
            ln -sf /lib/systemd/system/networking.service "$root/etc/systemd/system/multi-user.target.wants/networking.service"
        fi
    fi
    # Fixed images may carry cloud-init; keep its next boot from replacing network settings.
    mkdir -p "$root/etc/cloud/cloud.cfg.d"
    printf 'network:\n  config: disabled\nssh_pwauth: true\ndisable_root: false\n' > "$root/etc/cloud/cloud.cfg.d/99-dd-reinstall.cfg"
}

configure_main() {
    family=debian
    [ ! -f /etc/redhat-release ] || family=rhel
    read_value ssh_port; port=$value
    if [ -f "$data/password_hash" ]; then
        read_value password_hash
        [ -z "$value" ] || printf 'root:%s\n' "$value" | chpasswd -e
    fi
    mkdir -p /etc/ssh /run/sshd
    write_ssh_config '' "$port"
    if ! ssh-keygen -A >/dev/null 2>&1; then
        [ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -q -t rsa -N '' -f /etc/ssh/ssh_host_rsa_key
    fi
    /usr/sbin/sshd -t -f /etc/ssh/sshd_config.dd-new
    mv /etc/ssh/sshd_config.dd-new /etc/ssh/sshd_config
    configure_network '' "$family"
    if [ "$family" = rhel ]; then
        if command -v firewall-offline-cmd >/dev/null 2>&1; then
            firewall-offline-cmd --zone=public --add-port="$port/tcp"
        elif [ -f /etc/sysconfig/iptables ]; then
            write_iptables_rule /etc/sysconfig/iptables "$port"
        fi
        if [ "$port" != 22 ] && [ -f /etc/selinux/config ] && grep -Eq '^SELINUX=(enforcing|permissive)' /etc/selinux/config; then
            command -v semanage >/dev/null 2>&1 || { echo '非 22 SSH 端口需要目标镜像安装 semanage；未关闭 SELinux' >&2; return 1; }
            semanage port -a -t ssh_port_t -p tcp "$port" || semanage port -m -t ssh_port_t -p tcp "$port"
        fi
        # New files need the target SELinux labels on next boot.
        [ ! -f /etc/selinux/config ] || touch /.autorelabel
    fi
    # Use the ordinary SSH service rather than a socket still bound to port 22.
    if [ -f /lib/systemd/system/ssh.service ]; then
        mkdir -p /etc/systemd/system/multi-user.target.wants
        ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service
        if [ -f /lib/systemd/system/ssh.socket ]; then ln -sf /dev/null /etc/systemd/system/ssh.socket; fi
    fi
    if [ -f "$data/user-command.sh" ]; then
        command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1 || { echo '-cmd 需要目标系统安装 cron/cronie' >&2; return 1; }
        mkdir -p /etc/cron.d
        cat > "$data/run-command.sh" <<'COMMAND'
#!/bin/sh
# Make one attempt, without retrying arbitrary user side effects on every boot.
rm -f /etc/cron.d/dd-reinstall
if /bin/bash /root/dd-reinstall/user-command.sh; then
    rm -f /root/dd-reinstall/user-command.sh /root/dd-reinstall/run-command.sh
else
    echo '首次启动命令失败；保留脚本和日志，不自动重试。' >&2
    exit 1
fi
COMMAND
        chmod 700 "$data/run-command.sh" "$data/user-command.sh"
        printf '@reboot root /bin/sh /root/dd-reinstall/run-command.sh >>/var/log/dd-command.log 2>&1\n' > /etc/cron.d/dd-reinstall
        chmod 600 /etc/cron.d/dd-reinstall
    fi
    rm -f "$data/password_hash"
}

if [ "${DD_LIBRARY_ONLY:-0}" != 1 ]; then configure_main; fi
PAYLOAD
    cat > "$dir/late.sh" <<'PAYLOAD'
#!/bin/sh
set -eu
mkdir -p /target/root/dd-reinstall
cp -R /dd/. /target/root/dd-reinstall/
chmod -R go-rwx /target/root/dd-reinstall
in-target /bin/sh /root/dd-reinstall/configure.sh
PAYLOAD
    cat > "$dir/early.sh" <<'PAYLOAD'
#!/bin/sh
# Never return to partman after a failed network setup or image write.
hold() {
    trap - 0
    trap '' HUP INT TERM
    set +e
    echo "重装停止: $*。请使用服务商控制台检查；不会自动重启或继续分区。" >&2
    while :; do sleep 60; done
}
trap 'hold "安装 hook 意外退出"' 0
IFS= read -r mode < /dd/network_mode || hold '缺少网络模式'
case $mode in static|dhcp) ;; *) hold '网络模式无效' ;; esac
if [ "$mode" = static ] && [ "${1:-}" = network-only ]; then /bin/sh /dd/network.sh || hold '静态网络配置失败'; fi
if [ "${1:-}" = network-only ]; then
    trap - 0
    exit 0
fi
IFS= read -r url < /dd/image_url || hold '缺少镜像 URL 文件'
[ -n "$url" ] || hold '镜像 URL 为空'
# partman runs after network/mirror setup, unlike preseed/early_command.
IFS= read -r kind < /dd/image_kind || hold '缺少镜像类型'
case $kind in raw|rhel|windows) ;; *) hold '镜像类型无效' ;; esac
anna-install wget-udeb util-linux-udeb || hold '无法加载写盘工具'
case $kind in
    rhel) anna-install "xfs-modules-$(uname -r)-di" || hold '无法加载 XFS 驱动' ;;
    windows) anna-install ntfs-3g-udeb || hold '无法加载 NTFS 工具' ;;
esac
/bin/sh /dd/restore.sh || hold '镜像写入或配置失败'
hold '重启命令未完成'
PAYLOAD
    write_restore_script || return 1
    if [[ $image_kind == windows ]]; then write_windows_batch || return 1; fi
    chmod 700 "$dir/"*.sh
}

install_offlink_hook() {
    # udpkg runs netcfg's postinst before choose-mirror. Let the original
    # postinst finish clearing resolver files, then install our routes and DNS.
    local info=$workdir/root/var/lib/dpkg/info hook count=0
    for hook in "$info/netcfg.postinst" "$info/netcfg-static.postinst"; do
        if [[ ! -f $hook.before-dd ]]; then
            [[ -f $hook && -x $hook ]] || continue
            mv "$hook" "$hook.before-dd" || return 1
        fi
        cat > "$hook" <<'HOOK' || return 1
#!/bin/sh
"$0.before-dd" "$@" || exit $?
exec /bin/sh /dd/early.sh network-only
HOOK
        chmod 755 "$hook" || return 1
        count=$((count + 1))
    done
    ((count > 0)) || { error '安装器缺少 netcfg 配置入口，无法准备离网段网络'; return 1; }
}

write_restore_script() {
    cat > "$workdir/root/dd/restore.sh" <<'PAYLOAD'
#!/bin/sh
set -eu
data=/dd
read_value() { IFS= read -r value < "$data/$1"; }
copy_resolver() {
    # An absolute symlink in the image must not redirect cp into the installer root.
    rm -f "$2"
    cp "$1" "$2"
}
read_value image_url; url=$value
read_value image_kind; kind=$value
for tool in wget gzip dd blockdev blkid swapoff; do
    command -v "$tool" >/dev/null 2>&1 || { echo "缺少写盘工具: $tool" >&2; exit 1; }
done
disk=$(list-devices disk | head -n 1)
[ -n "$disk" ] && [ -b "$disk" ] || { echo '安装环境未找到磁盘' >&2; exit 1; }
disk=$(readlink -f "$disk")
sysdisk=/sys/class/block/${disk##*/}
inspect_disk() {
    [ -r "$sysdisk/dev" ] && [ -r /proc/self/mountinfo ] && [ -r /proc/swaps ] || return 1
    if [ -d "$sysdisk/dm" ] || [ -d "$sysdisk/md" ] || [ -f "$sysdisk/partition" ]; then
        echo "安装器给出的目标不是可直接覆盖的整盘: $disk" >&2
        return 1
    fi
    for backing in "$sysdisk"/slaves/*; do
        [ ! -e "$backing" ] || { echo "目标是活动映射设备: $disk" >&2; return 1; }
    done
    for item in "$sysdisk" "$sysdisk"/*/partition; do
        [ -e "$item" ] || continue
        node=${item%/partition}
        [ -d "$node/holders" ] || return 1
        for holder in "$node"/holders/*; do
            [ ! -e "$holder" ] || { echo "磁盘仍被活动映射占用: $holder" >&2; return 1; }
        done
        IFS= read -r devnum < "$node/dev" || return 1
        device=/dev/${node##*/}
        while read -r swap _; do
            [ "$swap" = "$device" ] || continue
            [ "$1" = release ] || { echo "交换设备仍在使用: $device" >&2; return 1; }
            swapoff "$device" || return 1
        done < /proc/swaps
        while read -r _ _ mount_dev _ _ _ details; do
            # mountinfo: optional fields, "-", filesystem type, source, options.
            fs_fields=${details#*- }
            fs_source=${fs_fields#* }
            [ "$mount_dev" = "$devnum" ] || [ "${fs_source%% *}" = "$device" ] || continue
            [ "$1" = release ] || { echo "磁盘仍有挂载: $device" >&2; return 1; }
            umount "$device" || return 1
            break
        done < /proc/self/mountinfo
    done
}
inspect_disk release
# Ask the kernel about other open partitions before the destructive write.
blockdev --rereadpt "$disk"
if command -v udevadm >/dev/null 2>&1; then udevadm settle; fi
inspect_disk check
rm -f /tmp/dd-download.status /tmp/dd-decode.status
# Explicit records detect upstream errors even if this /bin/sh lacks pipefail.
{
    if wget --no-check-certificate --timeout=30 --tries=1 -O - "$url"; then rc=0; else rc=$?; fi
    printf '%s\n' "$rc" > /tmp/dd-download.status
} | {
    if gzip -dc; then rc=0; else rc=$?; fi
    printf '%s\n' "$rc" > /tmp/dd-decode.status
} | {
    # Reject an empty/truncated decompressed image before changing the disk.
    dd bs=1 count=512 of=/tmp/dd-image-head
    [ "$(wc -c < /tmp/dd-image-head)" -eq 512 ]
    inspect_disk check || exit 1
    { cat /tmp/dd-image-head; cat; } | dd of="$disk" bs=1048576
}
# Some shells only wait for the final pipeline process. Wait for both producer records.
attempt=0
while [ ! -f /tmp/dd-download.status ] || [ ! -f /tmp/dd-decode.status ]; do
    attempt=$((attempt + 1)); [ "$attempt" -le 35 ] || exit 1
    sleep 1
done
IFS= read -r downloaded < /tmp/dd-download.status
IFS= read -r decoded < /tmp/dd-decode.status
[ "$downloaded" = 0 ] && [ "$decoded" = 0 ] || { echo '镜像下载或 gzip 校验失败' >&2; exit 1; }
sync
if [ "$kind" = raw ]; then
    /sbin/reboot
    exit 0
fi
blockdev --rereadpt "$disk"
if command -v udevadm >/dev/null 2>&1; then udevadm settle; fi

target=/mnt/dd-target
mkdir -p "$target"
found=
for attempt in 1 2 3 4 5; do
    for part in $(list-devices partition); do
        type=$(blkid -c /dev/null -s TYPE -o value "$part" 2>/dev/null || true)
        case "$kind:$type" in rhel:ext2|rhel:ext3|rhel:ext4|rhel:xfs|windows:ntfs) ;; *) continue ;; esac
        if [ "$kind" = windows ]; then mount.ntfs-3g -o ro "$part" "$target" || continue
        else mount -t "$type" -o ro "$part" "$target" || continue
        fi
        if { [ "$kind" = rhel ] && [ -f "$target/etc/redhat-release" ]; } ||
           { [ "$kind" = windows ] && [ -d "$target/Windows/System32" ]; }; then
            found=$part
            umount "$target"
            break
        fi
        umount "$target"
    done
    [ -z "$found" ] || break
    sleep 1
done
[ -n "$found" ] || { echo '未找到受支持的目标根分区（不支持 LVM/加密卷）' >&2; exit 1; }
mounted_dev=0; mounted_proc=0; mounted_sys=0
cleanup() {
    [ "$mounted_sys" = 0 ] || umount "$target/sys"
    [ "$mounted_proc" = 0 ] || umount "$target/proc"
    [ "$mounted_dev" = 0 ] || umount "$target/dev"
    umount "$target"
}
trap cleanup EXIT
if [ "$kind" = windows ]; then
    mount.ntfs-3g "$found" "$target"
    startup=$target/ProgramData/Microsoft/Windows/Start\ Menu/Programs/Startup
    [ -d "$startup" ] || { echo 'Windows 镜像不含预期 Startup 目录' >&2; exit 1; }
    cp "$data/net.bat" "$startup/dd-network.bat"
else
    mount "$found" "$target"
    mkdir -p "$target/root/dd-reinstall" "$target/dev" "$target/proc" "$target/sys"
    cp -R "$data/." "$target/root/dd-reinstall/"
    chmod -R go-rwx "$target/root/dd-reinstall"
    copy_resolver /etc/resolv.conf "$target/etc/resolv.conf"
    mount --bind /dev "$target/dev"; mounted_dev=1
    mount -t proc proc "$target/proc"; mounted_proc=1
    mount --bind /sys "$target/sys"; mounted_sys=1
    chroot "$target" /bin/sh /root/dd-reinstall/configure.sh
fi
cleanup
trap - EXIT
sync
/sbin/reboot
PAYLOAD
}

write_windows_batch() {
    local batch=$workdir/root/dd/net.bat
    local terminal='HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server'
    # ASCII and CRLF; no locale-dependent interface-name matching or UAC bypass.
    {
        cat <<'BATCH'
@echo off
setlocal
set "DD_CONFIGURED="
set "DD_BATCH=%~f0"
powershell -NoProfile -Command "if (([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }"
if errorlevel 1 (
  if /i "%~1"=="elevated" exit /b 1
  powershell -NoProfile -Command "Start-Process -FilePath $env:DD_BATCH -ArgumentList elevated -Verb RunAs -ErrorAction Stop"
  exit /b
)
BATCH
        printf 'for /f "tokens=1 delims=," %%%%a in (\x27getmac /v /fo csv /nh ^| find /i "%s"\x27) do (\n' "${net_mac//:/-}"
        printf '  if not "%%%%~a"=="" (\n'
        if [[ $network_mode == dhcp ]]; then
            printf '    netsh interface ipv4 set address name="%%%%~a" source=dhcp\n'
            printf '    if errorlevel 1 exit /b 1\n'
            printf '    netsh interface ipv4 set dnsservers name="%%%%~a" source=dhcp\n'
        else
            printf '    netsh interface ipv4 set address name="%%%%~a" source=static address=%s mask=%s gateway=%s\n' "$ip_addr" "$ip_mask" "$ip_gate"
            printf '    if errorlevel 1 exit /b 1\n'
            printf '    netsh interface ipv4 set dnsservers name="%%%%~a" source=static address=%s validate=no\n' "${ip_dns%% *}"
        fi
        printf '    if errorlevel 1 exit /b 1\n    set "DD_CONFIGURED=1"\n  )\n)\n'
        printf 'if not defined DD_CONFIGURED exit /b 1\n'
        if [[ -n $rdp_port ]]; then
            printf 'reg add "%s" /v fDenyTSConnections /t REG_DWORD /d 0 /f\n' "$terminal"
            printf 'if errorlevel 1 exit /b 1\n'
            printf 'reg add "%s" /v PortNumber /t REG_DWORD /d %s /f\n' "$terminal"'\WinStations\RDP-Tcp' "$rdp_port"
            printf 'if errorlevel 1 exit /b 1\n'
            printf 'reg add "%s" /v PortNumber /t REG_DWORD /d %s /f\n' "$terminal"'\Wds\rdpwd\Tds\tcp' "$rdp_port"
            printf 'if errorlevel 1 exit /b 1\n'
            printf 'reg add "%s" /v UserAuthentication /t REG_DWORD /d 0 /f\n' "$terminal"'\WinStations\RDP-Tcp'
            printf 'if errorlevel 1 exit /b 1\n'
            printf 'netsh advfirewall firewall add rule name="DD RDP" dir=in action=allow protocol=TCP localport=%s\n' "$rdp_port"
            printf 'if errorlevel 1 exit /b 1\npowershell -NoProfile -Command "Restart-Service TermService -Force"\nif errorlevel 1 exit /b 1\n'
        fi
        # Keep the original Windows system-volume expansion feature. DiskPart can
        # only extend into suitable adjacent free space; failures remain visible.
        cat <<'BATCH'
> "%TEMP%\dd-extend.txt" echo select volume %SystemDrive:~0,1%
>> "%TEMP%\dd-extend.txt" echo extend
diskpart /s "%TEMP%\dd-extend.txt"
if errorlevel 1 exit /b 1
del "%TEMP%\dd-extend.txt"
del "%~f0"
BATCH
    } | awk '{printf "%s\r\n", $0}' > "$batch"
}

generate_preseed() {
    local host folder protocol packages='openssh-server' dir=$workdir/root
    protocol=${selected_mirror%%:*}
    host=${selected_mirror#*://}; host=${host%%/*}
    folder=${selected_mirror#*://}
    if [[ $folder == */* ]]; then folder=/${folder#*/}; else folder=/; fi
    [[ $network_mode != static ]] || packages="$packages ifupdown resolvconf"
    [[ -z $command_b64 ]] || packages="$packages cron"
    {
        cat <<EOF
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select ${installer_iface:-auto}
d-i netcfg/get_hostname string $release
d-i netcfg/get_domain string local
d-i mirror/country string manual
d-i mirror/protocol string $protocol
d-i mirror/$protocol/hostname string $host
d-i mirror/$protocol/directory string $folder
d-i mirror/$protocol/proxy string
d-i mirror/suite string $dist
EOF
        if [[ $network_mode == static ]]; then
            if ((offlink)) || [[ $prefix == 32 ]]; then
                install_offlink_hook || return 1
                printf '%s\n' 'd-i netcfg/enable boolean false'
            else
                cat <<EOF
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/disable_dhcp boolean true
d-i netcfg/get_ipaddress string $ip_addr
d-i netcfg/get_netmask string $ip_mask
d-i netcfg/get_gateway string $ip_gate
d-i netcfg/get_nameservers string $ip_dns
d-i netcfg/confirm_static boolean true
EOF
            fi
        fi
        if [[ -n $image_url ]]; then
            printf '%s\n' 'd-i partman/early_command string /bin/sh /dd/early.sh'
            # No normal-install partition recipe: an image failure must never fall into partman.
            return 0
        fi
        cat <<EOF
d-i hw-detect/load_firmware boolean true
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password $password_hash
d-i clock-setup/utc boolean true
d-i time/zone string US/Eastern
d-i clock-setup/ntp boolean false
d-i lowmem/low note
d-i partman/early_command string debconf-set partman-auto/disk "\$(list-devices disk | head -n 1)"
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i pkgsel/include string $packages
tasksel tasksel/first multiselect
d-i debian-installer/allow_unauthenticated boolean true
d-i pkgsel/upgrade select none
d-i apt-setup/services-select multiselect
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string default
d-i grub-installer/force-efi-extra-removable boolean true
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/reboot boolean true
d-i preseed/late_command string /bin/sh /dd/late.sh || /bin/sh -c 'echo Target configuration failed >&2; while :; do sleep 60; done'
EOF
    } > "$dir/preseed.cfg"
}

generate_kickstart() {
    local dir=$workdir/root file encoded centos_arch=x86_64
    [[ $arch != i386 ]] || centos_arch=i386
    {
        cat <<EOF
install
url --url="$selected_mirror/$dist/os/$centos_arch/"
lang en_US.UTF-8
keyboard us
rootpw --iscrypted $password_hash
auth --useshadow --passalgo=sha512
firewall --enabled --port=$ssh_port:tcp
selinux --disabled
timezone --utc Asia/Hong_Kong
firstboot --disable
bootloader --location=mbr
zerombr
clearpart --all --initlabel
autopart
EOF
        if ((installer_vnc)); then
            vnc_password=$(openssl rand -base64 6) || return 1
            [[ $vnc_password =~ ^[A-Za-z0-9+/]{8}$ ]] || return 1
            printf 'vnc --password=%s\n' "$vnc_password"
        else printf 'text\n'
        fi
        case $dist in 6.[4-9]|6.10) printf 'unsupported_hardware\n' ;; esac
        if [[ $network_mode == dhcp ]]; then printf 'network --bootproto=dhcp --device=%s --onboot=yes\n' "${installer_iface:-$net_mac}"
        else printf 'network --bootproto=static --device=%s --ip=%s --netmask=%s --gateway=%s --nameserver=%s --onboot=yes\n' "${installer_iface:-$net_mac}" "$ip_addr" "$ip_mask" "$ip_gate" "${ip_dns// /,}"
        fi
        cat <<'EOF'
reboot
%packages
@base
openssh-server
cronie
%end
%post --interpreter=/bin/bash
set -e -o pipefail
# Any preparation failure must also stop Anaconda, not just configure.sh failures.
trap 'echo "Target preparation failed; install stopped" >&2; while :; do sleep 60 || :; done' EXIT
mkdir -p /root/dd-reinstall
chmod 700 /root/dd-reinstall
EOF
        for file in "$dir/dd/"*; do
            [[ -f $file ]] || continue
            case ${file##*/} in configure.sh|network_mode|ip_addr|ip_mask|ip_gate|ip_dns|prefix|net_mac|iface|ssh_port|password_hash|user-command.sh) ;; *) continue ;; esac
            encoded=$(base64 < "$file" | tr -d '\n') || return 1
            printf "printf '%%s' '%s' | base64 -d > '/root/dd-reinstall/%s'\n" "$encoded" "${file##*/}"
        done
        cat <<'EOF'
chmod -R go-rwx /root/dd-reinstall
if ! /bin/sh /root/dd-reinstall/configure.sh; then
    echo 'Target configuration failed; install stopped' > /dev/console
    while :; do sleep 60; done
fi
trap - EXIT
%end
EOF
    } > "$dir/ks.cfg"
}

pack_initrd() {
    local root=$workdir/root
    (set -o pipefail; cd "$root" && find . -print0 | cpio --null -o -H newc | gzip -9 > "$workdir/initrd.img") 2> "$workdir/pack.log" || {
        tail -n 20 "$workdir/pack.log" >&2; error 'initrd 打包失败'; return 1;
    }
    gzip -t "$workdir/initrd.img" || return 1
    [[ -s $workdir/initrd.img ]] || return 1
}

find_grub_tools() {
    local name tool
    for name in probe mkrelpath script-check editenv; do
        tool=$(command -v "grub-$name" || command -v "grub2-$name") || {
            error "需要 GRUB 2 工具 grub-$name（或 grub2-$name）"; return 1;
        }
        case $name in probe) grub_probe=$tool ;; mkrelpath) grub_relpath=$tool ;; script-check) grub_check=$tool ;; editenv) grub_editenv=$tool ;; esac
    done
}

detect_grub() {
    local candidate resolved abstraction fs secure
    for candidate in /etc/grub2-efi.cfg /etc/grub2.cfg /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
        [[ -f $candidate ]] || continue
        if [[ ! -d /sys/firmware/efi && $candidate == /etc/grub2-efi.cfg ]]; then continue; fi
        resolved=$(readlink -f "$candidate") || continue
        # Do not append to an EFI forwarding stub instead of the actual menu.
        grep -Eq '^[[:space:]]*(menuentry[[:space:]]|blscfg)' "$resolved" || continue
        grub_cfg=$resolved; break
    done
    if [[ -z $grub_cfg ]]; then
        # The original implementation supported grub.conf. Do not require GRUB 2
        # tools on a BIOS host that still uses that legacy bootloader.
        for candidate in /boot/grub/grub.conf /boot/grub/menu.lst; do
            [[ -f $candidate ]] || continue
            grep -Eq '^[[:space:]]*title[[:space:]]' "$candidate" || continue
            [[ ! -d /sys/firmware/efi ]] || { error '未适配 EFI GRUB Legacy'; return 1; }
            grub_cfg=$(readlink -f "$candidate") || return 1
            grub_kind=1; boot_once=0
            return 0
        done
        error '未找到可识别的 GRUB 主配置'; return 1
    fi
    find_grub_tools || return 1
    abstraction=$("$grub_probe" --target=abstraction /boot) || return 1
    fs=$("$grub_probe" --target=fs /boot) || return 1
    if [[ -n $abstraction || ( $fs != ext2 && $fs != xfs ) ]]; then
        # Keep the original ability to boot from a GRUB-readable LVM/RAID/COW
        # filesystem. Such layouts cannot safely clear a file-backed one-shot flag.
        boot_once=0
        log '此 /boot 使用旧版持久默认项方式；失败后手动重启需在控制台选择启动项'
    fi
    for secure in /sys/firmware/efi/efivars/SecureBoot-*; do
        [[ -f $secure ]] || continue
        [[ $(od -An -tu1 -j4 -N1 "$secure" | tr -d ' ') != 1 ]] || { error '当前实现不支持 Secure Boot'; return 1; }
    done
    if [[ -d /sys/firmware/efi && $arch == i386 ]]; then
        error '不支持在 UEFI VPS 上引导 i386 安装器'; return 1
    fi
    if [[ -d /sys/firmware/efi && ( $release == centos || $image_kind == rhel ) ]]; then
        error 'CentOS 6/已知 RHEL raw 镜像仅适配 BIOS VPS；UEFI 请选 Debian/Ubuntu 或匹配的自定义 raw 镜像'; return 1
    fi
}

boot_options() {
    local options extra='' token
    local cmdline=()
    if [[ $release == centos ]]; then options="ks=file:/ks.cfg ksdevice=${installer_iface:-$net_mac}"
    # /preseed.cfg is loaded by initrd-preseed automatically. Specifying preseed/file
    # as well runs file-preseed and preseed/early_command a second time.
    else options="auto=true priority=critical hostname=$release domain=local"
    fi
    ((legacy_names == 0)) || extra="$extra net.ifnames=0 biosdevname=0"
    ((noipv6 == 0)) || extra="$extra ipv6.disable=1"
    if [[ -n $console ]]; then extra="$extra console=$console"
    elif [[ -r /proc/cmdline ]]; then
        read -r -a cmdline < /proc/cmdline || return 1
        for token in "${cmdline[@]}"; do
            [[ $token =~ ^console=[a-zA-Z0-9,._=-]+$ ]] && extra="$extra $token"
        done
    fi
    if [[ $release == centos ]]; then printf '%s%s\n' "$options" "$extra"
    else printf '%s --- %s\n' "$options" "$extra"
    fi
}

write_grub_candidate() {
    local destination=$1 uuid=$2 kernel=$3 initrd=$4 envpath=$5 id=$6 options=$7
    local kernel_cmd=linux initrd_cmd=initrd
    if grep -Eq '^[[:space:]]*linuxefi[[:space:]]' "$grub_cfg"; then kernel_cmd=linuxefi; initrd_cmd=initrdefi
    elif grep -Eq '^[[:space:]]*linux16[[:space:]]' "$grub_cfg"; then kernel_cmd=linux16; initrd_cmd=initrd16
    fi
    cat "$grub_cfg" > "$destination" || return 1
    cat >> "$destination" <<EOF || return 1

# dd.sh: isolated install entry; existing menu indices and grubenv remain unchanged.
menuentry 'Reinstall VPS [$release $dist $arch]' --id '$id' {
    search --no-floppy --fs-uuid --set=root '$uuid'
    $kernel_cmd '$kernel' $options
    $initrd_cmd '$initrd'
}
EOF
    if ((boot_once == 0)); then
        printf "set default='%s'\nset timeout=3\n" "$id" >> "$destination"
        return $?
    fi
    cat >> "$destination" <<EOF
search --no-floppy --fs-uuid --set=dd_boot '$uuid'
if [ -f (\$dd_boot)$envpath ]; then
    load_env --file=(\$dd_boot)$envpath dd_reinstall
    if [ "\$dd_reinstall" = '$id' ]; then
        set dd_reinstall=
        if save_env --file=(\$dd_boot)$envpath dd_reinstall; then
            set default='$id'
            set timeout=3
        else
            echo 'Cannot clear one-time install flag; keeping original boot selection.'
            sleep 5
        fi
    fi
fi
EOF
}

write_legacy_candidate() {
    local destination=$1 options=$2 block old_kernel roots kernel initrd count
    block=$(awk '/^[[:space:]]*title[[:space:]]/ {n++} n == 1 {print}' "$grub_cfg") || return 1
    old_kernel=$(printf '%s\n' "$block" | awk '$1 == "kernel" {print $2; exit}') || return 1
    [[ $old_kernel == /* ]] || { error '无法从 Legacy 首个启动项确定内核路径'; return 1; }
    roots=$(printf '%s\n' "$block" | awk '$1 == "root" || $1 == "rootnoverify" || $1 == "uuid" || ($1 == "find" && /--set-root/) {print}') || return 1
    if [[ $old_kernel == /boot/* ]]; then kernel=$install_dir/vmlinuz; initrd=$install_dir/initrd.img
    else kernel=/${install_dir#/boot/}/vmlinuz; initrd=/${install_dir#/boot/}/initrd.img
    fi
    count=$(awk '/^[[:space:]]*title[[:space:]]/ {n++} END {print n+0}' "$grub_cfg") || return 1
    ((count > 0)) || return 1
    # Append the install entry, preserving all old entry indices and their content.
    awk -v entry_index="$count" '
        BEGIN {print "default " entry_index; print "fallback 0"; print "timeout 3"}
        /^[[:space:]]*title[[:space:]]/ {entries=1}
        !entries && /^[[:space:]]*(default|fallback|timeout)([[:space:]]|=)/ {next}
        {print}
    ' "$grub_cfg" > "$destination" || return 1
    {
        printf '\ntitle Reinstall VPS [%s %s %s]\n' "$release" "$dist" "$arch"
        [[ -z $roots ]] || printf '%s\n' "$roots"
        printf 'kernel %s %s\ninitrd %s\n' "$kernel" "$options" "$initrd"
    } >> "$destination"
}

commit_boot() {
    local uuid kernel initrd envpath id options candidate
    install_dir=$(mktemp -d /boot/dd-reinstall.XXXXXXXX) || return 1
    chmod 700 "$install_dir" || return 1
    cp "$workdir/initrd.img" "$install_dir/initrd.img" || return 1
    cp "$workdir/vmlinuz" "$install_dir/vmlinuz" || return 1
    cmp "$workdir/initrd.img" "$install_dir/initrd.img" && cmp "$workdir/vmlinuz" "$install_dir/vmlinuz" || return 1
    if ((grub_kind == 1)); then
        options=$(boot_options) || return 1
        candidate=$(mktemp "${grub_cfg}.dd-new.XXXXXXXX") || return 1
        if ! write_legacy_candidate "$candidate" "$options"; then rm -f "$candidate"; return 1; fi
        commit_grub_config "$candidate"
        return $?
    fi
    uuid=$("$grub_probe" --target=fs_uuid "$install_dir") || return 1
    [[ $uuid =~ ^[a-zA-Z0-9-]+$ ]] || { error 'GRUB 文件系统 UUID 无效'; return 1; }
    id=${install_dir##*/}
    # mkrelpath canonicalizes its argument; the environment file must exist first.
    envpath=
    if ((boot_once)); then
        "$grub_editenv" "$install_dir/grubenv" create || return 1
        "$grub_editenv" "$install_dir/grubenv" set "dd_reinstall=$id" || return 1
        "$grub_editenv" "$install_dir/grubenv" list | grep -Fx "dd_reinstall=$id" >/dev/null || return 1
        envpath=$("$grub_relpath" "$install_dir/grubenv") || return 1
    fi
    kernel=$("$grub_relpath" "$install_dir/vmlinuz") || return 1
    initrd=$("$grub_relpath" "$install_dir/initrd.img") || return 1
    local grub_path_pattern='^/[a-zA-Z0-9_@./-]+$'
    [[ $kernel =~ $grub_path_pattern && $initrd =~ $grub_path_pattern ]] || return 1
    if ((boot_once)); then [[ $envpath =~ $grub_path_pattern ]] || return 1; fi
    options=$(boot_options) || return 1
    candidate=$(mktemp "${grub_cfg}.dd-new.XXXXXXXX") || return 1
    if ! write_grub_candidate "$candidate" "$uuid" "$kernel" "$initrd" "$envpath" "$id" "$options" || ! "$grub_check" "$candidate"; then
        rm -f "$candidate"; return 1
    fi
    commit_grub_config "$candidate"
}

commit_grub_config() {
    local candidate=$1
    grub_backup=$install_dir/grub.cfg.before-dd
    cp -p "$grub_cfg" "$grub_backup" || { rm -f "$candidate"; return 1; }
    if ! chmod --reference="$grub_cfg" "$candidate" || ! chown --reference="$grub_cfg" "$candidate"; then rm -f "$candidate"; return 1; fi
    # Set before rename: even a signal immediately after the rename triggers rollback.
    grub_changed=1
    mv -f "$candidate" "$grub_cfg" || return 1
    sync || return 1
    log "安装文件已就绪，原 GRUB 备份: $grub_backup"
}

cleanup() {
    local status=$?
    trap - EXIT
    if ((grub_changed && !keep_boot)); then
        if [[ -f $grub_backup ]] && cp -p "$grub_backup" "${grub_cfg}.dd-rollback" && mv -f "${grub_cfg}.dd-rollback" "$grub_cfg"; then
            log '已恢复本次修改前的 GRUB 配置'
        else
            log "无法自动恢复 GRUB，请从 $grub_backup 手动恢复"
            keep_boot=1
        fi
    fi
    if ((!keep_boot)) && [[ -n $install_dir && $install_dir == /boot/dd-reinstall.* ]]; then rm -rf -- "$install_dir"; fi
    [[ -z $workdir ]] || rm -rf -- "$workdir"
    return "$status"
}

describe_target() {
    if [[ -z $image_url ]]; then
        printf '将清空此 VPS 的单块磁盘。网络安装 %s %s (%s)，网络=%s，SSH=%s\n' "$release" "$dist" "$arch" "$network_mode" "$ssh_port"
    else
        local address=${image_url%%[?#]*} authority path
        path=${address#*://}; authority=${path%%/*}
        address=${address%%://*}://${authority##*@}${path#"$authority"}
        printf '将清空此 VPS 的单块磁盘。镜像=%s，类型=%s，地址=%s，安装网络=%s\n' "${image_label:-自定义磁盘镜像}" "$image_kind" "$address" "$network_mode"
        case $image_kind in rhel) printf '目标 SSH 端口=%s\n' "$ssh_port" ;; windows) printf '目标 RDP 端口=%s\n' "${rdp_port:-沿用镜像}" ;; esac
    fi
}

confirm_target() {
    local answer
    describe_target
    ((assume_yes == 0)) || return 0
    IFS= read -r -p '直接回车开始，输入其他内容取消: ' answer || return 1
    [[ -z $answer ]] || { log '已取消重装'; return 1; }
}

main() {
    # Explicit checks guard destructive boundaries; errexit also catches unexpected failures.
    set -Ee -o pipefail
    umask 077
    defaults
    if (($#)); then
        local parsed=0
        parse_args "$@" || parsed=$?
        ((parsed != 2)) || return 0
        ((parsed == 0)) || return "$parsed"
    else interactive=1; menu
    fi
    normalize_options
    [[ $(uname -s) == Linux ]] || { error '仅支持在 Linux VPS 上运行'; return 1; }
    [[ $EUID == 0 ]] || { error '请使用 root 执行'; return 1; }
    [[ ! -d /proc/vz || -d /proc/bc ]] || { error '不支持 OpenVZ 容器'; return 1; }
    [[ ! -f /run/systemd/container ]] || { error '不支持容器中的系统重装'; return 1; }
    if [[ $preset_boot == uefi && ! -d /sys/firmware/efi ]] || [[ $preset_boot == bios && -d /sys/firmware/efi ]]; then
        error "镜像 $image_label 需要 $preset_boot 引导"; return 1
    fi
    confirm_target || return 1
    install_dependencies
    # flock releases automatically, including signals; no persistent task-state system.
    exec 9>/var/lock/dd-reinstall.lock
    flock -n 9 || { error '已有重装脚本正在运行'; return 1; }
    workdir=$(mktemp -d /tmp/dd-reinstall.XXXXXXXX)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    trap 'printf "[dd] 第 %s 行失败；未完成重装准备。\n" "$LINENO" >&2' ERR
    detect_network
    get_disk >/dev/null
    detect_grub
    if [[ -z $image_url || $image_kind == rhel ]]; then make_password_hash; else password=; fi
    log "准备 $release $dist $arch 安装环境，网络模式 $network_mode"
    fetch_installer
    prepare_initrd
    write_payloads
    if [[ $release == centos ]]; then generate_kickstart; else generate_preseed; fi
    pack_initrd
    commit_boot
    if ((installer_vnc)); then log "CentOS 安装器 VNC 临时密码：$vnc_password"; fi
    log '准备完成，即将重启进入安装环境；可通过服务商控制台查看进度。'
    # shutdown may signal this process before reboot returns; preserve valid boot files first.
    keep_boot=1
    if ! reboot; then keep_boot=0; error '重启失败，恢复原引导'; return 1; fi
}

# Keep the function name advertised by the original menu. Merely sourcing this
# file still performs no work; explicitly calling this function starts reinstall.
InstallNET_Main() { bash "$DD_REINSTALL_SCRIPT" "$@"; }

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
