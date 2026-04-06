#!/bin/bash

#CentOS、Rocky静态IP代码部分来自hiCasper
#Windows部分来自veip007
#基于以上添加了custom password、自定义端口

GET_NETCMD(){
    if [[ $static == 'true' ]];then
        MAINIP=$(ip route get 1 | awk -F 'src ' '{print $2}' | awk '{print $1}')
        GATEWAYIP=$(ip route | grep default | awk '{print $3}')
        SUBNET=$(ip -o -f inet addr show | awk '/scope global/{sub(/[^.]+\//,"0/",$4);print $4}' | head -1 | awk -F '/' '{print $2}')
        value=$(( 0xffffffff ^ ((1 << (32 - $SUBNET)) - 1) ))
        NETMASK="$(( (value >> 24) & 0xff )).$(( (value >> 16) & 0xff )).$(( (value >> 8) & 0xff )).$(( value & 0xff ))"
        
        #有些VPS获取到的掩码是255.255.255.255(/32)，显然是不对的，所以对此情况另外设置一个可能更合适的掩码
        if [[ "$NETMASK" == "255.255.255.255" ]];then
            echo -e "\033[33m[警告] 检测到 /32 (255.255.255.255) 掩码！\033[0m"
            echo -e "\033[33m只有在 OVH/Hetzner 等少数服务商此掩码才合法(P2P路由)。大多数普通 VPS 使用此掩码会导致断网失联！\033[0m"
            echo -e "当前提取的网络信息 -> MAINIP: ${MAINIP} | GATEWAYIP: ${GATEWAYIP} | NETMASK: ${NETMASK}"
            
            # 当出现 /32 掩码时，默认进入手动修改模式 (Default No)
            read -p "确认保留此 /32 掩码吗？若不确定请按回车修改！(Keep /32 mask?)[y/N][Default No]: " mask_input
            case $mask_input in
                [yY][eE][sS]|[yY]) 
                    NETCMD="--ip-addr ${MAINIP} --ip-gate ${GATEWAYIP} --ip-mask ${NETMASK}" 
                    ;;
                *) 
                    echo -e "\n\033[32m-> 进入网络信息手动修正模式...\033[0m"
                    UPDATE_NETCMD 
                    ;;
            esac
        else
            # 正常掩码的通用确认流程
            echo -e "MAINIP: ${MAINIP}\nGATEWAYIP: ${GATEWAYIP}\nNETMASK: ${NETMASK}"
            read -p "请检查是否正确(is ok?)!!![Y/n][Default Yes]: " input
            case $input in
                [yY][eE][sS]|[yY]) NETCMD="--ip-addr ${MAINIP} --ip-gate ${GATEWAYIP} --ip-mask ${NETMASK}" ;;
                [nN][oO]|[nN]) UPDATE_NETCMD ;;
                *) NETCMD="--ip-addr ${MAINIP} --ip-gate ${GATEWAYIP} --ip-mask ${NETMASK}" ;;
            esac
        fi
    else
        NETCMD=""
    fi
}

UPDATE_NETCMD(){
    read -p "输入IP(Input IP)[Default ${MAINIP}]: " NEW_MAINIP
    read -p "输入网关(Input GATEWAYIP)[Default ${GATEWAYIP}]: " NEW_GATEWAYIP
    read -p "输入掩码(Input NETMASK)[Default ${NETMASK}]: " NEW_NETMASK
    if [[ ${NEW_MAINIP} ]];then MAINIP=${NEW_MAINIP}; fi
    if [[ ${NEW_GATEWAYIP} ]];then GATEWAYIP=${NEW_GATEWAYIP}; fi
    if [[ ${NEW_NETMASK} ]];then NETMASK=${NEW_NETMASK}; fi

    echo -e "MAINIP: ${MAINIP}\nGATEWAYIP: ${GATEWAYIP}\nNETMASK: ${NETMASK}"
    read -p "请再次检查是否正确(is ok?)!!![Y/n][Default Yes]: " input
    case $input in
        [yY][eE][sS]|[yY]) NETCMD="--ip-addr ${MAINIP} --ip-gate ${GATEWAYIP} --ip-mask ${NETMASK}" ;;
        [nN][oO]|[nN]) UPDATE_NETCMD ;;
        *) NETCMD="--ip-addr ${MAINIP} --ip-gate ${GATEWAYIP} --ip-mask ${NETMASK}" ;;
    esac
}

RHELImageBootConf() {
    touch /tmp/bootconf.sh
    echo '#!/bin/sh'>/tmp/bootconf.sh

    if [ "$static" == 'true' ]; then
        cat >>/tmp/bootconf.sh <<EOF
sed -i 's/dhcp/static/' /etc/sysconfig/network-scripts/ifcfg-eth0;
echo -e "IPADDR=$MAINIP\nNETMASK=$NETMASK\nGATEWAY=$GATEWAYIP\nDNS1=8.8.8.8\nDNS2=8.8.4.4" >> /etc/sysconfig/network-scripts/ifcfg-eth0
EOF
    fi
    echo "echo root:${password:-haoduck.com}|chpasswd;" >>/tmp/bootconf.sh
    if [[ ${port} ]];then
    cat >>/tmp/bootconf.sh <<EOF
sed -ri 's/^#?Port.*/Port ${port}/g' /etc/ssh/sshd_config; \
sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config; \
sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config;
EOF
    fi
    cat >>/tmp/bootconf.sh <<EOF
rm -f /etc/rc.d/rc.local
cp -f /etc/rc.d/rc.local.bak /etc/rc.d/rc.local
rm -rf /bootconf.sh
shutdown -r now
EOF
        export RHEL_INJECT="sync; umount \$(list-devices partition |head -n1); mount -t ext4 \$(list-devices partition |head -n1) /mnt; cp -f /mnt/etc/rc.d/rc.local /mnt/etc/rc.d/rc.local.bak; chmod +x /mnt/etc/rc.d/rc.local; cp -f /bootconf.sh /mnt/bootconf.sh; chmod 755 /mnt/bootconf.sh; echo \"/bootconf.sh\" >> /mnt/etc/rc.d/rc.local; sync; umount /mnt; "
}

if [[ $EUID -ne 0 ]]; then
    clear
    echo "请使用ROOT用户执行脚本(run as root)" 1>&2
    exit 1
fi

if [[ `command -v apt-get` ]];then apt-get update && apt-get install -y curl wget file xz-utils; fi
if [[ `command -v yum` ]];then yum install -y curl wget file xz; fi


clear
read -p "是否使用DHCP(Use DHCP)[Y/n][Default No]: " dhcp
case $dhcp in
    [yY][eE][sS]|[yY]) static=false ;;
    [nN][oO]|[nN]) static=true ;;
    *) static=true ;;
esac
GET_NETCMD

geo=$(curl -fskSL --connect-timeout 5 -m 10 http://ipinfo.io/json) || geo=$(curl -fskSL --connect-timeout 5 -m 10 http://api.ip.sb/geoip -A Mozilla|sed 's/,/,\n/g') || geo=''
if [[ $(echo "$geo" | grep "country"|grep "CN") ]];then
    DEFAULT_CN=Y
else
    DEFAULT_CN=n
fi

print_linux(){
    echo ""
    echo "请选择您需要的镜像包:"
    echo ""
    echo "  1) Debian 13 [custom password]"
    echo "  2) Debian 12 [custom password]"
    echo "  3) Debian 11 [custom password]"
    echo "  4) Debian 10 [custom password]"
    echo "  5) Ubuntu 20.04 [custom password]"
    echo "  6) Ubuntu 18.04 [custom password]"
    echo "  7) Ubuntu 16.04 [custom password]"
    echo "  8) CentOS 6 [custom password]"
    echo ""
    echo "  ————————以下起均为dd模式————————"
    echo ""
    echo "  以下CentOS、Rocky部分来自hiCasper"
    echo ""
    echo "  9) CentOS 7.8 [custom password]"
    echo "  10) CentOS 7.6 [custom password]"
    echo "  11) Rocky Linux 8.6 [custom password]"
}


print_menu(){
    clear
    echo ""
    echo "IP: $MAINIP"
    echo "GATEWAY: $GATEWAYIP"
    echo "NETMASK: $NETMASK"
    print_linux
    echo ""
    echo ""
    echo "  100) 自定义直链(custom url)"
    echo ""
    echo "  自定义镜像也可以使用：InstallNET_Main -dd '您的直连'"
    while [[ -z $N ]];do
        echo -n "请输入编号(Input number): "
        read N
    done
}

print_menu

RUN(){
    N=$1
    if [[ $N == 100 ]];then read -p "Input your url: " DDURL; fi
    read -p "使用国内源(Use CN mirror)[Y/n][Default: $DEFAULT_CN]: " input
    if [[ -z $input ]];then input=$DEFAULT_CN; fi
    case $input in
        [yY][eE][sS]|[yY]) CN=true ;;
        [nN][oO]|[nN]) CN=false ;;
    esac
    if [[ $CN == 'true' ]];then
        echo "  选择一个源"
        echo "  1) mirrors.aliyun.com [Default]"
        echo "  2) mirrors.tencent.com"
        echo "  3) mirrors.163.com"
        echo "  4) mirrors.huaweicloud.com"
        echo "  5) mirrors.tuna.tsinghua.edu.cn"
        echo "  6) mirrors.ustc.edu.cn"
        echo "  7) mirrors.tencentyun.com [仅内网Intranet!!!]"
        echo "  99) 手动输入,示例: http://mirrors.aliyun.com"
        read -p "选择一个源(Input number): " input
        case $input in
            1) mirror=http://mirrors.aliyun.com ;;
            2) mirror=http://mirrors.tencent.com ;;
            3) mirror=http://mirrors.163.com ;;
            4) mirror=http://mirrors.huaweicloud.com ;;
            5) mirror=http://mirrors.tuna.tsinghua.edu.cn ;;
            6) mirror=http://mirrors.ustc.edu.cn ;;
            7) mirror=http://mirrors.tencentyun.com ;;
        esac
        CMIRROR="--mirror ${mirror}/centos/"
        CVMIRROR="--mirror ${mirror}/centos-vault/"
        DMIRROR="--mirror ${mirror}/debian/"
        UMIRROR="--mirror ${mirror}/ubuntu/"
    else
        CMIRROR=''
        CVMIRROR=''
        DMIRROR=''
        UMIRROR=''
    fi
    case $N in
        1|2|3|4|5|6|7|8|9|10|11)
        read -p "Input root password[Default: haoduck.com]: " password
        read -p "Input ssh port[Default: 22]: " port
        echo -e "\nPassword: ${password:-haoduck.com}\nPort: ${port:-22}\n"
        ;;
    esac
    read -p "回车确认开始执行(Press any key to continue)，CTRL+C退出"
    case $N in
        1) InstallNET_Main -d 13 -v 64 $NETCMD $DMIRROR -p ${password:-haoduck.com} -port ${port:-22} ;;
        2) InstallNET_Main -d 12 -v 64 $NETCMD $DMIRROR -p ${password:-haoduck.com} -port ${port:-22} ;;
        3) InstallNET_Main -d 11 -v 64 $NETCMD $DMIRROR -p ${password:-haoduck.com} -port ${port:-22} ;;
        4) InstallNET_Main -d 10 -v 64 $NETCMD $DMIRROR -p ${password:-haoduck.com} -port ${port:-22} ;;
        5) InstallNET_Main -u 20.04 -v 64 $NETCMD $UMIRROR -p ${password:-haoduck.com} -port ${port:-22} ;;
        6) InstallNET_Main -u 18.04 -v 64 $NETCMD $UMIRROR -p ${password:-haoduck.com} -port ${port:-22} ;;
        7) InstallNET_Main -u 16.04 -v 64 $NETCMD $UMIRROR -p ${password:-haoduck.com} -port ${port:-22} ;;
        8) InstallNET_Main -c 6.10 -v 64 $NETCMD $CVMIRROR -p ${password:-haoduck.com} -port ${port:-22} ;;
        9) RHELImageBootConf; InstallNET_Main $NETCMD -dd 'https://api.moetools.net/get/centos-78-image' $DMIRROR ;;
        10) RHELImageBootConf; InstallNET_Main $NETCMD -dd 'https://api.moetools.net/get/centos-76-image' $DMIRROR ;;
        11) RHELImageBootConf; InstallNET_Main $NETCMD -dd 'https://api.moetools.net/get/rocky-8-image' $DMIRROR ;;
        100) InstallNET_Main $NETCMD -dd "$DDURL" $DMIRROR ;;
        *) echo "Wrong input!" ;;
    esac
}
RUN $N


InstallNET_Main() {

    ## License: GPL
    ## It can reinstall Debian, Ubuntu, CentOS system with network.
    ## Default root password: MoeClub.org
    ## Blog: https://moeclub.org
    ## Written By MoeClub.org

    export tmpVER=''
    export tmpDIST=''
    export tmpURL=''
    export tmpWORD=''
    export tmpMirror=''
    export ipAddr=''
    export ipMask=''
    export ipGate=''
    export ipDNS='8.8.8.8'
    export IncDisk='default'
    export interface=''
    export interfaceSelect=''
    export Relese=''
    export sshPORT='22'
    export ddMode='0'
    export setNet='0'
    export setRDP='0'
    export setIPv6='0'
    export isMirror='0'
    export FindDists='0'
    export loaderMode='0'
    export IncFirmware='0'
    export SpikCheckDIST='0'
    export setInterfaceName='0'
    export UNKNOWHW='0'
    export UNVER='6.4'
    export GRUBDIR=''
    export GRUBFILE=''
    export GRUBVER=''
    export VER=''
    export setCMD=''
    export setConsole=''

    while [[ $# -ge 1 ]]; do
      case $1 in
        -v|--ver)
          shift
          tmpVER="$1"
          shift
          ;;
        -d|--debian)
          shift
          Relese='Debian'
          tmpDIST="$1"
          shift
          ;;
        -u|--ubuntu)
          shift
          Relese='Ubuntu'
          tmpDIST="$1"
          shift
          ;;
        -c|--centos)
          shift
          Relese='CentOS'
          tmpDIST="$1"
          shift
          ;;
        -dd|--image)
          shift
          ddMode='1'
          tmpURL="$1"
          shift
          ;;
        -p|--password)
          shift
          tmpWORD="$1"
          shift
          ;;
        -i|--interface)
          shift
          interfaceSelect="$1"
          shift
          ;;
        --ip-addr)
          shift
          ipAddr="$1"
          shift
          ;;
        --ip-mask)
          shift
          ipMask="$1"
          shift
          ;;
        --ip-gate)
          shift
          ipGate="$1"
          shift
          ;;
        --ip-dns)
          shift
          ipDNS="$1"
          shift
          ;;
        --dev-net)
          shift
          setInterfaceName='1'
          ;;
        --loader)
          shift
          loaderMode='1'
          ;;
        -apt|-yum|--mirror)
          shift
          isMirror='1'
          tmpMirror="$1"
          shift
          ;;
        -rdp)
          shift
          setRDP='1'
          WinRemote="$1"
          shift
          ;;
        -cmd)
          shift
          setCMD="$1"
          shift
          ;;
        -console)
          shift
          setConsole="$1"
          shift
          ;;
        -firmware)
          shift
          IncFirmware="1"
          ;;
        -port)
          shift
          sshPORT="$1"
          shift
          ;;
        --noipv6)
          shift
          setIPv6='1'
          ;;
        -a|--auto|-m|--manual|-ssl)
          shift
          ;;
        *)
          if [[ "$1" != 'error' ]]; then echo -ne "\nInvaild option: '$1'\n\n"; fi
          echo -ne " Usage:\n\tbash $(basename $0)\t-d/--debian [\033[33m\033[04mdists-name\033[0m]\n\t\t\t\t-u/--ubuntu [\033[04mdists-name\033[0m]\n\t\t\t\t-c/--centos [\033[04mdists-name\033[0m]\n\t\t\t\t-v/--ver [32/i386|64/\033[33m\033[04mamd64\033[0m] [\033[33m\033[04mdists-verison\033[0m]\n\t\t\t\t--ip-addr/--ip-gate/--ip-mask\n\t\t\t\t-apt/-yum/--mirror\n\t\t\t\t-dd/--image\n\t\t\t\t-p [linux password]\n\t\t\t\t-port [linux ssh port]\n"
          exit 1;
          ;;
        esac
      done


    function dependence(){
      Full='0';
      for BIN_DEP in `echo "$1" |sed 's/,/\n/g'`
        do
          if [[ -n "$BIN_DEP" ]]; then
            Found='0';
            for BIN_PATH in `echo "$PATH" |sed 's/:/\n/g'`
              do
                ls $BIN_PATH/$BIN_DEP >/dev/null 2>&1;
                if [ $? == '0' ]; then
                  Found='1';
                  break;
                fi
              done
            if [ "$Found" == '1' ]; then
              echo -en "[\033[32mok\033[0m]\t";
            else
              Full='1';
              echo -en "[\033[31mNot Install\033[0m]";
            fi
            echo -en "\t$BIN_DEP\n";
          fi
        done
      if [ "$Full" == '1' ]; then
        echo -ne "\n\033[31mError! \033[0mPlease use '\033[33mapt-get\033[0m' or '\033[33myum\033[0m' install it.\n\n\n"
        exit 1;
      fi
    }

    function selectMirror(){
      [ $# -ge 3 ] || exit 1
      Relese=$(echo "$1" |sed -r 's/(.*)/\L\1/')
      DIST=$(echo "$2" |sed 's/\ //g' |sed -r 's/(.*)/\L\1/')
      VER=$(echo "$3" |sed 's/\ //g' |sed -r 's/(.*)/\L\1/')
      New=$(echo "$4" |sed 's/\ //g')
      [ -n "$Relese" ] && [ -n "$DIST" ] && [ -n "$VER" ] || exit 1
      if [ "$Relese" == "debian" ] || [ "$Relese" == "ubuntu" ]; then
        [ "$DIST" == "focal" ] && legacy="legacy-" || legacy=""
        TEMP="SUB_MIRROR/dists/${DIST}/main/installer-${VER}/current/${legacy}images/netboot/${Relese}-installer/${VER}/initrd.gz"
      elif [ "$Relese" == "centos" ]; then
        TEMP="SUB_MIRROR/${DIST}/os/${VER}/isolinux/initrd.img"
      fi
      [ -n "$TEMP" ] || exit 1
      mirrorStatus=0
      declare -A MirrorBackup
      MirrorBackup=(["debian0"]="" ["debian1"]="http://deb.debian.org/debian" ["debian2"]="http://archive.debian.org/debian" ["ubuntu0"]="" ["ubuntu1"]="http://archive.ubuntu.com/ubuntu" ["ubuntu2"]="http://ports.ubuntu.com" ["centos0"]="" ["centos1"]="http://mirror.centos.org/centos" ["centos2"]="http://vault.centos.org")
      echo "$New" |grep -q '^http://\|^https://\|^ftp://' && MirrorBackup[${Relese}0]="$New"
      for mirror in $(echo "${!MirrorBackup[@]}" |sed 's/\ /\n/g' |sort -n |grep "^$Relese")
        do
          Current="${MirrorBackup[$mirror]}"
          [ -n "$Current" ] || continue
          MirrorURL=`echo "$TEMP" |sed "s#SUB_MIRROR#${Current}#g"`
          wget --no-check-certificate --spider --timeout=3 -o /dev/null "$MirrorURL"
          [ $? -eq 0 ] && mirrorStatus=1 && break
        done
      [ $mirrorStatus -eq 1 ] && echo "$Current" || exit 1
    }

    function netmask() {
      n="${1:-32}"
      b=""
      m=""
      for((i=0;i<32;i++)){
        [ $i -lt $n ] && b="${b}1" || b="${b}0"
      }
      for((i=0;i<4;i++)){
        s=`echo "$b"|cut -c$[$[$i*8]+1]-$[$[$i+1]*8]`
        [ "$m" == "" ] && m="$((2#${s}))" || m="${m}.$((2#${s}))"
      }
      echo "$m"
    }

    function getInterface(){
      interface=""
      Interfaces=`cat /proc/net/dev |grep ':' |cut -d':' -f1 |sed 's/\s//g' |grep -iv '^lo\|^sit\|^stf\|^gif\|^dummy\|^vmnet\|^vir\|^gre\|^ipip\|^ppp\|^bond\|^tun\|^tap\|^ip6gre\|^ip6tnl\|^teql\|^ocserv\|^vpn'`
      defaultRoute=`ip route show default |grep "^default"`
      for item in `echo "$Interfaces"`
        do
          [ -n "$item" ] || continue
          echo "$defaultRoute" |grep -q "$item"
          [ $? -eq 0 ] && interface="$item" && break
        done
      echo "$interface"
    }

    function getDisk(){
      disks=`lsblk | sed 's/[[:space:]]*$//g' |grep "disk$" |cut -d' ' -f1 |grep -v "fd[0-9]*\|sr[0-9]*" |head -n1`
      [ -n "$disks" ] || echo ""
      echo "$disks" |grep -q "/dev"
      [ $? -eq 0 ] && echo "$disks" || echo "/dev/$disks"
    }

    function diskType(){
      echo `udevadm info --query all "$1" 2>/dev/null |grep 'ID_PART_TABLE_TYPE' |cut -d'=' -f2`
    }

    function getGrub(){
      Boot="${1:-/boot}"
      folder=`find "$Boot" -type d -name "grub*" 2>/dev/null |head -n1`
      [ -n "$folder" ] || return
      fileName=`ls -1 "$folder" 2>/dev/null |grep '^grub.conf$\|^grub.cfg$'`
      if [ -z "$fileName" ]; then
        ls -1 "$folder" 2>/dev/null |grep -q '^grubenv$'
        [ $? -eq 0 ] || return
        folder=`find "$Boot" -type f -name "grubenv" 2>/dev/null |xargs dirname |grep -v "^$folder" |head -n1`
        [ -n "$folder" ] || return
        fileName=`ls -1 "$folder" 2>/dev/null |grep '^grub.conf$\|^grub.cfg$'`
      fi
      [ -n "$fileName" ] || return
      [ "$fileName" == "grub.cfg" ] && ver="0" || ver="1"
      echo "${folder}:${fileName}:${ver}"
    }

    function lowMem(){
      mem=`grep "^MemTotal:" /proc/meminfo 2>/dev/null |grep -o "[0-9]*"`
      [ -n "$mem" ] || return 0
      [ "$mem" -le "524288" ] && return 1 || return 0
    }

    if [[ "$loaderMode" == "0" ]]; then
      Grub=`getGrub "/boot"`
      [ -z "$Grub" ] && echo -ne "Error! Not Found grub.\n" && exit 1;
      GRUBDIR=`echo "$Grub" |cut -d':' -f1`
      GRUBFILE=`echo "$Grub" |cut -d':' -f2`
      GRUBVER=`echo "$Grub" |cut -d':' -f3`
    fi

    [ -n "$Relese" ] || Relese='Debian'
    linux_relese=$(echo "$Relese" |sed 's/\ //g' |sed -r 's/(.*)/\L\1/')
    clear && echo -e "\n\033[36m# Check Dependence\033[0m\n"

    if [[ "$ddMode" == '1' ]]; then
      dependence iconv;
      linux_relese='debian';
      tmpDIST='bullseye';
      tmpVER='amd64';
    fi

    [ -n "$ipAddr" ] && [ -n "$ipMask" ] && [ -n "$ipGate" ] && setNet='1';
    if [ "$setNet" == "0" ]; then
      dependence ip
      [ -n "$interface" ] || interface=`getInterface`
      iAddr=`ip addr show dev $interface |grep "inet.*" |head -n1 |grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\/[0-9]\{1,2\}'`
      ipAddr=`echo ${iAddr} |cut -d'/' -f1`
      ipMask=`netmask $(echo ${iAddr} |cut -d'/' -f2)`
      ipGate=`ip route show default |grep "^default" |grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' |head -n1`
    fi
    if [ -z "$interface" ]; then
        dependence ip
        [ -n "$interface" ] || interface=`getInterface`
    fi
    IPv4="$ipAddr"; MASK="$ipMask"; GATE="$ipGate";

    [ -n "$IPv4" ] && [ -n "$MASK" ] && [ -n "$GATE" ] && [ -n "$ipDNS" ] || {
      echo -ne '\nError: Invalid network config\n\n'
      bash $0 error;
      exit 1;
    }

    if [[ "$Relese" == 'Debian' ]] || [[ "$Relese" == 'Ubuntu' ]]; then
      dependence wget,awk,grep,sed,cut,cat,lsblk,cpio,gzip,find,dirname,basename;
    elif [[ "$Relese" == 'CentOS' ]]; then
      dependence wget,awk,grep,sed,cut,cat,lsblk,cpio,gzip,find,dirname,basename,file,xz;
    fi
    [ -n "$tmpWORD" ] && dependence openssl
    [[ -n "$tmpWORD" ]] && myPASSWORD="$(openssl passwd -1 "$tmpWORD")";
    [[ -z "$myPASSWORD" ]] && myPASSWORD='$1$4BJZaD0A$y1QykUnJ6mXprENfwpseH0';

    tempDisk=`getDisk`; [ -n "$tempDisk" ] && IncDisk="$tempDisk"

    case `uname -m` in aarch64|arm64) VER="arm64";; x86|i386|i686) VER="i386";; x86_64|amd64) VER="amd64";; *) VER="";; esac
    tmpVER="$(echo "$tmpVER" |sed -r 's/(.*)/\L\1/')";
    if [[ "$VER" != "arm64" ]] && [[ -n "$tmpVER" ]]; then
      case "$tmpVER" in i386|i686|x86|32) VER="i386";; amd64|x86_64|x64|64) [[ "$Relese" == 'CentOS' ]] && VER='x86_64' || VER='amd64';; *) VER='';; esac
    fi

    if [[ ! -n "$VER" ]]; then
      echo "Error! Not Architecture."
      bash $0 error;
      exit 1;
    fi

    if [[ -z "$tmpDIST" ]]; then
      [ "$Relese" == 'Debian' ] && tmpDIST='bookworm';
      [ "$Relese" == 'Ubuntu' ] && tmpDIST='noble';
      [ "$Relese" == 'CentOS' ] && tmpDIST='6.10';
    fi

    if [[ -n "$tmpDIST" ]]; then
      if [[ "$Relese" == 'Debian' ]]; then
        SpikCheckDIST='0'
        DIST="$(echo "$tmpDIST" |sed -r 's/(.*)/\L\1/')";
        echo "$DIST" |grep -q '[0-9]';
        [[ $? -eq '0' ]] && {
          isDigital="$(echo "$DIST" |grep -o '[\.0-9]\{1,\}' |sed -n '1h;1!H;$g;s/\n//g;$p' |cut -d'.' -f1)";
          [[ -n $isDigital ]] && {
            [[ "$isDigital" == '7' ]] && DIST='wheezy';
            [[ "$isDigital" == '8' ]] && DIST='jessie';
            [[ "$isDigital" == '9' ]] && DIST='stretch';
            [[ "$isDigital" == '10' ]] && DIST='buster';
            [[ "$isDigital" == '11' ]] && DIST='bullseye';
            [[ "$isDigital" == '12' ]] && DIST='bookworm';
            [[ "$isDigital" == '13' ]] && DIST='trixie';
          }
        }
        LinuxMirror=$(selectMirror "$Relese" "$DIST" "$VER" "$tmpMirror")
      fi
      if [[ "$Relese" == 'Ubuntu' ]]; then
        SpikCheckDIST='0'
        DIST="$(echo "$tmpDIST" |sed -r 's/(.*)/\L\1/')";
        echo "$DIST" |grep -q '[0-9]';
        [[ $? -eq '0' ]] && {
          isDigital="$(echo "$DIST" |grep -o '[\.0-9]\{1,\}' |sed -n '1h;1!H;$g;s/\n//g;$p')";
          [[ -n $isDigital ]] && {
            [[ "$isDigital" == '12.04' ]] && DIST='precise';
            [[ "$isDigital" == '14.04' ]] && DIST='trusty';
            [[ "$isDigital" == '16.04' ]] && DIST='xenial';
            [[ "$isDigital" == '18.04' ]] && DIST='bionic';
            [[ "$isDigital" == '20.04' ]] && DIST='focal';
            # [[ "$isDigital" == '22.04' ]] && DIST='jammy';
          }
        }
        LinuxMirror=$(selectMirror "$Relese" "$DIST" "$VER" "$tmpMirror")
      fi
      if [[ "$Relese" == 'CentOS' ]]; then
        SpikCheckDIST='1'
        DISTCheck="$(echo "$tmpDIST" |grep -o '[\.0-9]\{1,\}' |head -n1)";
        LinuxMirror=$(selectMirror "$Relese" "$DISTCheck" "$VER" "$tmpMirror")
        ListDIST="$(wget --no-check-certificate -qO- "$LinuxMirror/dir_sizes" |cut -f2 |grep '^[0-9]')"
        DIST="$(echo "$ListDIST" |grep "^$DISTCheck" |head -n1)"
        [[ -z "$DIST" ]] && {
          echo -ne '\nThe dists version not found in this mirror, Please check it! \n\n'
          bash $0 error;
          exit 1;
        }
        wget --no-check-certificate -qO- "$LinuxMirror/$DIST/os/$VER/.treeinfo" |grep -q 'general';
        [[ $? != '0' ]] && {
            echo -ne "\nThe version not found in this mirror, Please change mirror try again! \n\n";
            exit 1;
        }
      fi
    fi

    if [[ -z "$LinuxMirror" ]]; then
      echo -ne "\033[31mError! \033[0mInvaild mirror! \n"
      [ "$Relese" == 'Debian' ] && echo -en "\033[33mexample:\033[0m http://deb.debian.org/debian\n\n";
      [ "$Relese" == 'Ubuntu' ] && echo -en "\033[33mexample:\033[0m http://archive.ubuntu.com/ubuntu\n\n";
      [ "$Relese" == 'CentOS' ] && echo -en "\033[33mexample:\033[0m http://mirror.centos.org/centos\n\n";
      bash $0 error;
      exit 1;
    fi

    if [[ "$SpikCheckDIST" == '0' ]]; then
      DistsList="$(wget --no-check-certificate -qO- "$LinuxMirror/dists/" |grep -o 'href=.*/"' |cut -d'"' -f2 |sed '/-\|old\|Debian\|experimental\|stable\|test\|sid\|devel/d' |grep '^[^/]' |sed -n '1h;1!H;$g;s/\n//g;s/\//\;/g;$p')";
      for CheckDEB in `echo "$DistsList" |sed 's/;/\n/g'`
        do
          [[ "$CheckDEB" == "$DIST" ]] && FindDists='1' && break;
        done
      [[ "$FindDists" == '0' ]] && {
        echo -ne '\nThe dists version not found, Please check it! \n\n'
        bash $0 error;
        exit 1;
      }
    fi

    if [[ "$ddMode" == '1' ]]; then
      if [[ -n "$tmpURL" ]]; then
        DDURL="$tmpURL"
        echo "$DDURL" |grep -q '^http://\|^ftp://\|^https://';
        [[ $? -ne '0' ]] && echo 'Please input vaild URL,Only support http://, ftp:// and https:// !' && exit 1;
      else
        echo 'Please input vaild image URL! ';
        exit 1;
      fi
    fi

    clear && echo -e "\n\033[36m# Install\033[0m\n"

    [[ "$ddMode" == '1' ]] && echo -ne "\033[34mAuto Mode\033[0m insatll \033[33mWindows\033[0m\n[\033[33m$DDURL\033[0m]\n"

    if [ -z "$interfaceSelect" ]; then
      if [[ "$linux_relese" == 'debian' ]] || [[ "$linux_relese" == 'ubuntu' ]]; then
        interfaceSelect="auto"
      elif [[ "$linux_relese" == 'centos' ]]; then
        interfaceSelect="link"
      fi
    fi

    if [[ "$linux_relese" == 'centos' ]]; then
      if [[ "$DIST" != "$UNVER" ]]; then
        awk 'BEGIN{print '${UNVER}'-'${DIST}'}' |grep -q '^-'
        if [ $? != '0' ]; then
          UNKNOWHW='1';
          echo -en "\033[33mThe version lower then \033[31m$UNVER\033[33m may not support in auto mode! \033[0m\n";
        fi
        awk 'BEGIN{print '${UNVER}'-'${DIST}'+0.59}' |grep -q '^-'
        if [ $? == '0' ]; then
          echo -en "\n\033[31mThe version higher then \033[33m6.10 \033[31mis not support in current! \033[0m\n\n"
          exit 1;
        fi
      fi
    fi

    echo -e "\n[\033[33m$Relese\033[0m] [\033[33m$DIST\033[0m] [\033[33m$VER\033[0m] Downloading..."

    if [[ "$linux_relese" == 'debian' ]] || [[ "$linux_relese" == 'ubuntu' ]]; then
      [ "$DIST" == "focal" ] && legacy="legacy-" || legacy=""
      wget --no-check-certificate -qO '/tmp/initrd.img' "${LinuxMirror}/dists/${DIST}/main/installer-${VER}/current/${legacy}images/netboot/${linux_relese}-installer/${VER}/initrd.gz"
      [[ $? -ne '0' ]] && echo -ne "\033[31mError! \033[0mDownload 'initrd.img' for \033[33m$linux_relese\033[0m failed! \n" && exit 1
      wget --no-check-certificate -qO '/tmp/vmlinuz' "${LinuxMirror}/dists/${DIST}${inUpdate}/main/installer-${VER}/current/${legacy}images/netboot/${linux_relese}-installer/${VER}/linux"
      [[ $? -ne '0' ]] && echo -ne "\033[31mError! \033[0mDownload 'vmlinuz' for \033[33m$linux_relese\033[0m failed! \n" && exit 1
      MirrorHost="$(echo "$LinuxMirror" |awk -F'://|/' '{print $2}')";
      MirrorFolder="$(echo "$LinuxMirror" |awk -F''${MirrorHost}'' '{print $2}')";
      [ -n "$MirrorFolder" ] || MirrorFolder="/"
    elif [[ "$linux_relese" == 'centos' ]]; then
      wget --no-check-certificate -qO '/tmp/initrd.img' "${LinuxMirror}/${DIST}/os/${VER}/isolinux/initrd.img"
      [[ $? -ne '0' ]] && echo -ne "\033[31mError! \033[0mDownload 'initrd.img' for \033[33m$linux_relese\033[0m failed! \n" && exit 1
      wget --no-check-certificate -qO '/tmp/vmlinuz' "${LinuxMirror}/${DIST}/os/${VER}/isolinux/vmlinuz"
      [[ $? -ne '0' ]] && echo -ne "\033[31mError! \033[0mDownload 'vmlinuz' for \033[33m$linux_relese\033[0m failed! \n" && exit 1
    else
      bash $0 error;
      exit 1;
    fi
    if [[ "$linux_relese" == 'debian' ]]; then
      if [[ "$IncFirmware" == '1' ]]; then
        wget --no-check-certificate -qO '/tmp/firmware.cpio.gz' "http://cdimage.debian.org/cdimage/unofficial/non-free/firmware/${DIST}/current/firmware.cpio.gz"
        [[ $? -ne '0' ]] && echo -ne "\033[31mError! \033[0mDownload 'firmware' for \033[33m$linux_relese\033[0m failed! \n" && exit 1
      fi
      if [[ "$ddMode" == '1' ]]; then
        vKernel_udeb=$(wget --no-check-certificate -qO- "http://$DISTMirror/dists/$DIST/main/installer-$VER/current/images/udeb.list" |grep '^acpi-modules' |head -n1 |grep -o '[0-9]\{1,2\}.[0-9]\{1,2\}.[0-9]\{1,2\}-[0-9]\{1,2\}' |head -n1)
        [[ -z "vKernel_udeb" ]] && vKernel_udeb="4.19.0-17"
      fi
    fi

    if [[ "$loaderMode" == "0" ]]; then
      [[ ! -f "${GRUBDIR}/${GRUBFILE}" ]] && echo "Error! Not Found ${GRUBFILE}. " && exit 1;

      [[ ! -f "${GRUBDIR}/${GRUBFILE}.old" ]] && [[ -f "${GRUBDIR}/${GRUBFILE}.bak" ]] && mv -f "${GRUBDIR}/${GRUBFILE}.bak" "${GRUBDIR}/${GRUBFILE}.old";
      mv -f "${GRUBDIR}/${GRUBFILE}" "${GRUBDIR}/${GRUBFILE}.bak";
      [[ -f "${GRUBDIR}/${GRUBFILE}.old" ]] && cat "${GRUBDIR}/${GRUBFILE}.old" >"${GRUBDIR}/${GRUBFILE}" || cat "${GRUBDIR}/${GRUBFILE}.bak" >"${GRUBDIR}/${GRUBFILE}";
    else
      GRUBVER='-1'
    fi

    [[ "$GRUBVER" == '0' ]] && {
      READGRUB='/tmp/grub.read'
      cat $GRUBDIR/$GRUBFILE |sed -n '1h;1!H;$g;s/\n/%%%%%%%/g;$p' |grep -om 1 'menuentry\ [^{]*{[^}]*}%%%%%%%' |sed 's/%%%%%%%/\n/g' >$READGRUB
      LoadNum="$(cat $READGRUB |grep -c 'menuentry ')"
      if [[ "$LoadNum" -eq '1' ]]; then
        cat $READGRUB |sed '/^$/d' >/tmp/grub.new;
      elif [[ "$LoadNum" -gt '1' ]]; then
        CFG0="$(awk '/menuentry /{print NR}' $READGRUB|head -n 1)";
        CFG2="$(awk '/menuentry /{print NR}' $READGRUB|head -n 2 |tail -n 1)";
        CFG1="";
        for tmpCFG in `awk '/}/{print NR}' $READGRUB`
          do
            [ "$tmpCFG" -gt "$CFG0" -a "$tmpCFG" -lt "$CFG2" ] && CFG1="$tmpCFG";
          done
        [[ -z "$CFG1" ]] && {
          echo "Error! read $GRUBFILE. ";
          exit 1;
        }

        sed -n "$CFG0,$CFG1"p $READGRUB >/tmp/grub.new;
        [[ -f /tmp/grub.new ]] && [[ "$(grep -c '{' /tmp/grub.new)" -eq "$(grep -c '}' /tmp/grub.new)" ]] || {
          echo -ne "\033[31mError! \033[0mNot configure $GRUBFILE. \n";
          exit 1;
        }
      fi
      [ ! -f /tmp/grub.new ] && echo "Error! $GRUBFILE. " && exit 1;
      sed -i "/menuentry.*/c\menuentry\ \'Install OS \[$DIST\ $VER\]\'\ --class debian\ --class\ gnu-linux\ --class\ gnu\ --class\ os\ \{" /tmp/grub.new
      sed -i "/echo.*Loading/d" /tmp/grub.new;
      INSERTGRUB="$(awk '/menuentry /{print NR}' $GRUBDIR/$GRUBFILE|head -n 1)"
    }

    [[ "$GRUBVER" == '1' ]] && {
      CFG0="$(awk '/title[\ ]|title[\t]/{print NR}' $GRUBDIR/$GRUBFILE|head -n 1)";
      CFG1="$(awk '/title[\ ]|title[\t]/{print NR}' $GRUBDIR/$GRUBFILE|head -n 2 |tail -n 1)";
      [[ -n $CFG0 ]] && [ -z $CFG1 -o $CFG1 == $CFG0 ] && sed -n "$CFG0,$"p $GRUBDIR/$GRUBFILE >/tmp/grub.new;
      [[ -n $CFG0 ]] && [ -z $CFG1 -o $CFG1 != $CFG0 ] && sed -n "$CFG0,$[$CFG1-1]"p $GRUBDIR/$GRUBFILE >/tmp/grub.new;
      [[ ! -f /tmp/grub.new ]] && echo "Error! configure append $GRUBFILE. " && exit 1;
      sed -i "/title.*/c\title\ \'Install OS \[$DIST\ $VER\]\'" /tmp/grub.new;
      sed -i '/^#/d' /tmp/grub.new;
      INSERTGRUB="$(awk '/title[\ ]|title[\t]/{print NR}' $GRUBDIR/$GRUBFILE|head -n 1)"
    }

    if [[ "$loaderMode" == "0" ]]; then
      [[ -n "$(grep 'linux.*/\|kernel.*/' /tmp/grub.new |awk '{print $2}' |tail -n 1 |grep '^/boot/')" ]] && Type='InBoot' || Type='NoBoot';

      LinuxKernel="$(grep 'linux.*/\|kernel.*/' /tmp/grub.new |awk '{print $1}' |head -n 1)";
      [[ -z "$LinuxKernel" ]] && echo "Error! read grub config! " && exit 1;
      LinuxIMG="$(grep 'initrd.*/' /tmp/grub.new |awk '{print $1}' |tail -n 1)";
      [ -z "$LinuxIMG" ] && sed -i "/$LinuxKernel.*\//a\\\tinitrd\ \/" /tmp/grub.new && LinuxIMG='initrd';

      [[ "$setInterfaceName" == "1" ]] && Add_OPTION="net.ifnames=0 biosdevname=0" || Add_OPTION=""
      [[ "$setIPv6" == "1" ]] && Add_OPTION="$Add_OPTION ipv6.disable=1"
      
      lowMem || Add_OPTION="$Add_OPTION lowmem=+2"

      if [[ "$linux_relese" == 'debian' ]] || [[ "$linux_relese" == 'ubuntu' ]]; then
        BOOT_OPTION="auto=true $Add_OPTION hostname=$linux_relese domain=$linux_relese quiet"
      elif [[ "$linux_relese" == 'centos' ]]; then
        BOOT_OPTION="ks=file://ks.cfg $Add_OPTION ksdevice=$interfaceSelect"
      fi
      
      [ -n "$setConsole" ] && BOOT_OPTION="$BOOT_OPTION --- console=$setConsole"

      [[ "$Type" == 'InBoot' ]] && {
        sed -i "/$LinuxKernel.*\//c\\\t$LinuxKernel\\t\/boot\/vmlinuz $BOOT_OPTION" /tmp/grub.new;
        sed -i "/$LinuxIMG.*\//c\\\t$LinuxIMG\\t\/boot\/initrd.img" /tmp/grub.new;
      }

      [[ "$Type" == 'NoBoot' ]] && {
        sed -i "/$LinuxKernel.*\//c\\\t$LinuxKernel\\t\/vmlinuz $BOOT_OPTION" /tmp/grub.new;
        sed -i "/$LinuxIMG.*\//c\\\t$LinuxIMG\\t\/initrd.img" /tmp/grub.new;
      }

      sed -i '$a\\n' /tmp/grub.new;
      
      sed -i ''${INSERTGRUB}'i\\n' $GRUBDIR/$GRUBFILE;
      sed -i ''${INSERTGRUB}'r /tmp/grub.new' $GRUBDIR/$GRUBFILE;
      [[ -f  $GRUBDIR/grubenv ]] && sed -i 's/saved_entry/#saved_entry/g' $GRUBDIR/grubenv;
    fi

    [[ -d /tmp/boot ]] && rm -rf /tmp/boot;
    mkdir -p /tmp/boot;
    cd /tmp/boot;

    if [[ "$linux_relese" == 'debian' ]] || [[ "$linux_relese" == 'ubuntu' ]]; then
      COMPTYPE="gzip";
    elif [[ "$linux_relese" == 'centos' ]]; then
      COMPTYPE="$(file ../initrd.img |grep -o ':.*compressed data' |cut -d' ' -f2 |sed -r 's/(.*)/\L\1/' |head -n1)"
      [[ -z "$COMPTYPE" ]] && echo "Detect compressed type fail." && exit 1;
    fi
    CompDected='0'
    for COMP in `echo -en 'gzip\nlzma\nxz'`
      do
        if [[ "$COMPTYPE" == "$COMP" ]]; then
          CompDected='1'
          if [[ "$COMPTYPE" == 'gzip' ]]; then
            NewIMG="initrd.img.gz"
          else
            NewIMG="initrd.img.$COMPTYPE"
          fi
          mv -f "/tmp/initrd.img" "/tmp/$NewIMG"
          break;
        fi
      done
    [[ "$CompDected" != '1' ]] && echo "Detect compressed type not support." && exit 1;
    [[ "$COMPTYPE" == 'lzma' ]] && UNCOMP='xz --format=lzma --decompress';
    [[ "$COMPTYPE" == 'xz' ]] && UNCOMP='xz --decompress';
    [[ "$COMPTYPE" == 'gzip' ]] && UNCOMP='gzip -d';

    $UNCOMP < /tmp/$NewIMG | cpio --extract --verbose --make-directories --no-absolute-filenames >>/dev/null 2>&1

    if [[ "$linux_relese" == 'debian' ]] || [[ "$linux_relese" == 'ubuntu' ]]; then
    CurrentKernelVersion=`ls -1 ./lib/modules 2>/dev/null |head -n1`
    [ -n "$CurrentKernelVersion" ] && SelectLowmem="di-utils-exit-installer,driver-injection-disk-detect,fdisk-udeb,netcfg-static,parted-udeb,partman-auto,partman-ext3,ata-modules-${CurrentKernelVersion}-di,efi-modules-${CurrentKernelVersion}-di,sata-modules-${CurrentKernelVersion}-di,scsi-modules-${CurrentKernelVersion}-di,scsi-nic-modules-${CurrentKernelVersion}-di" || SelectLowmem=""
    cat >/tmp/boot/preseed.cfg<<EOF
    d-i debian-installer/locale string en_US.UTF-8
    d-i debian-installer/country string US
    d-i debian-installer/language string en

    d-i console-setup/layoutcode string us

    d-i keyboard-configuration/xkb-keymap string us
    d-i lowmem/low note
    d-i anna/choose_modules_lowmem multiselect $SelectLowmem

    d-i netcfg/choose_interface select $interfaceSelect

    d-i netcfg/disable_autoconfig boolean true
    d-i netcfg/dhcp_failed note
    d-i netcfg/dhcp_options select Configure network manually
    d-i netcfg/get_ipaddress string $IPv4
    d-i netcfg/get_netmask string $MASK
    d-i netcfg/get_gateway string $GATE
    d-i netcfg/get_nameservers string $ipDNS
    d-i netcfg/no_default_route boolean true
    d-i netcfg/confirm_static boolean true

    d-i hw-detect/load_firmware boolean true

    d-i mirror/country string manual
    d-i mirror/http/hostname string $MirrorHost
    d-i mirror/http/directory string $MirrorFolder
    d-i mirror/http/proxy string

    d-i passwd/root-login boolean ture
    d-i passwd/make-user boolean false
    d-i passwd/root-password-crypted password $myPASSWORD
    d-i user-setup/allow-password-weak boolean true
    d-i user-setup/encrypt-home boolean false

    d-i clock-setup/utc boolean true
    d-i time/zone string US/Eastern
    d-i clock-setup/ntp boolean false

    d-i preseed/early_command string anna-install libfuse2-udeb fuse-udeb ntfs-3g-udeb libcrypto1.1-udeb libpcre2-8-0-udeb libssl1.1-udeb libuuid1-udeb zlib1g-udeb wget-udeb
    d-i partman/early_command string [[ -n "\$(blkid -t TYPE='vfat' -o device)" ]] && umount "\$(blkid -t TYPE='vfat' -o device)"; \
    debconf-set partman-auto/disk "\$(list-devices disk |head -n1)"; \
    wget -qO- '$DDURL' |gunzip -dc |/bin/dd of=\$(list-devices disk |head -n1); \
    mount.ntfs-3g \$(list-devices partition |head -n1) /mnt; \
    cd '/mnt/ProgramData/Microsoft/Windows/Start Menu/Programs'; \
    cd Start* || cd start*; \
    cp -f '/net.bat' './net.bat'; \
    ${RHEL_INJECT:-}\
    /sbin/reboot; \
    umount /media || true; \

    d-i partman-partitioning/confirm_write_new_label boolean true
    d-i partman/mount_style select uuid
    d-i partman/choose_partition select finish
    d-i partman-auto/method string regular
    d-i partman-auto/init_automatically_partition select Guided - use entire disk
    d-i partman-auto/choose_recipe select All files in one partition (recommended for new users)
    d-i partman-md/device_remove_md boolean true
    d-i partman-lvm/device_remove_lvm boolean true
    d-i partman-lvm/confirm boolean true
    d-i partman-lvm/confirm_nooverwrite boolean true
    d-i partman/confirm boolean true
    d-i partman/confirm_nooverwrite boolean true

    d-i debian-installer/allow_unauthenticated boolean true

    tasksel tasksel/first multiselect minimal
    d-i pkgsel/update-policy select none
    d-i pkgsel/include string openssh-server
    d-i pkgsel/upgrade select none
    d-i apt-setup/services-select multiselect

    popularity-contest popularity-contest/participate boolean false

    d-i grub-installer/only_debian boolean true
    d-i grub-installer/bootdev string $IncDisk
    d-i grub-installer/force-efi-extra-removable boolean true
    d-i finish-install/reboot_in_progress note
    d-i debian-installer/exit/reboot boolean true
    d-i preseed/late_command string \
    sed -ri 's/^#?Port.*/Port ${sshPORT}/g' /target/etc/ssh/sshd_config; \
    sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/g' /target/etc/ssh/sshd_config; \
    sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/g' /target/etc/ssh/sshd_config; \
    echo '@reboot root cat /etc/run.sh 2>/dev/null |base64 -d >/tmp/run.sh; rm -rf /etc/run.sh; sed -i /^@reboot/d /etc/crontab; bash /tmp/run.sh' >>/target/etc/crontab; \
    echo '' >>/target/etc/crontab; \
    echo '${setCMD}' >/target/etc/run.sh;
    EOF

    if [[ "$loaderMode" != "0" ]] && [[ "$setNet" == '0' ]]; then
      sed -i '/netcfg\/disable_autoconfig/d' /tmp/boot/preseed.cfg
      sed -i '/netcfg\/dhcp_options/d' /tmp/boot/preseed.cfg
      sed -i '/netcfg\/get_.*/d' /tmp/boot/preseed.cfg
      sed -i '/netcfg\/confirm_static/d' /tmp/boot/preseed.cfg
    fi

    if [[ "$linux_relese" == 'debian' ]]; then
      sed -i '/user-setup\/allow-password-weak/d' /tmp/boot/preseed.cfg
      sed -i '/user-setup\/encrypt-home/d' /tmp/boot/preseed.cfg
      sed -i '/pkgsel\/update-policy/d' /tmp/boot/preseed.cfg
      sed -i 's/umount\ \/media.*true\;\ //g' /tmp/boot/preseed.cfg
      [[ -f '/tmp/firmware.cpio.gz' ]] && gzip -d < /tmp/firmware.cpio.gz | cpio --extract --verbose --make-directories --no-absolute-filenames >>/dev/null 2>&1
    else
      sed -i '/d-i\ grub-installer\/force-efi-extra-removable/d' /tmp/boot/preseed.cfg
    fi

    [[ "$ddMode" == '1' ]] && {
    WinNoDHCP(){
      echo -ne "for\0040\0057f\0040\0042tokens\00753\0052\0042\0040\0045\0045i\0040in\0040\0050\0047netsh\0040interface\0040show\0040interface\0040\0136\0174more\0040\00533\0040\0136\0174findstr\0040\0057I\0040\0057R\0040\0042本地\0056\0052\0040以太\0056\0052\0040Local\0056\0052\0040Ethernet\0042\0047\0051\0040do\0040\0050set\0040EthName\0075\0045\0045j\0051\r\nnetsh\0040\0055c\0040interface\0040ip\0040set\0040address\0040name\0075\0042\0045EthName\0045\0042\0040source\0075static\0040address\0075$IPv4\0040mask\0075$MASK\0040gateway\0075$GATE\r\nnetsh\0040\0055c\0040interface\0040ip\0040add\0040dnsservers\0040name\0075\0042\0045EthName\0045\0042\0040address\00758\00568\00568\00568\0040index\00751\0040validate\0075no\r\n\r\n" >>'/tmp/boot/net.tmp';
    }
    WinRDP(){
      echo -ne "netsh\0040firewall\0040set\0040portopening\0040protocol\0075ALL\0040port\0075$WinRemote\0040name\0075RDP\0040mode\0075ENABLE\0040scope\0075ALL\0040profile\0075ALL\r\nnetsh\0040firewall\0040set\0040portopening\0040protocol\0075ALL\0040port\0075$WinRemote\0040name\0075RDP\0040mode\0075ENABLE\0040scope\0075ALL\0040profile\0075CURRENT\r\nreg\0040add\0040\0042HKLM\0134SYSTEM\0134CurrentControlSet\0134Control\0134Network\0134NewNetworkWindowOff\0042\0040\0057f\r\nreg\0040add\0040\0042HKLM\0134SYSTEM\0134CurrentControlSet\0134Control\0134Terminal\0040Server\0042\0040\0057v\0040fDenyTSConnections\0040\0057t\0040reg\0137dword\0040\0057d\00400\0040\0057f\r\nreg\0040add\0040\0042HKLM\0134SYSTEM\0134CurrentControlSet\0134Control\0134Terminal\0040Server\0134Wds\0134rdpwd\0134Tds\0134tcp\0042\0040\0057v\0040PortNumber\0040\0057t\0040reg\0137dword\0040\0057d\0040$WinRemote\0040\0057f\r\nreg\0040add\0040\0042HKLM\0134SYSTEM\0134CurrentControlSet\0134Control\0134Terminal\0040Server\0134WinStations\0134RDP\0055Tcp\0042\0040\0057v\0040PortNumber\0040\0057t\0040reg\0137dword\0040\0057d\0040$WinRemote\0040\0057f\r\nreg\0040add\0040\0042HKLM\0134SYSTEM\0134CurrentControlSet\0134Control\0134Terminal\0040Server\0134WinStations\0134RDP\0055Tcp\0042\0040\0057v\0040UserAuthentication\0040\0057t\0040reg\0137dword\0040\0057d\00400\0040\0057f\r\nFOR\0040\0057F\0040\0042tokens\00752\0040delims\0075\0072\0042\0040\0045\0045i\0040in\0040\0050\0047SC\0040QUERYEX\0040TermService\0040\0136\0174FINDSTR\0040\0057I\0040\0042PID\0042\0047\0051\0040do\0040TASKKILL\0040\0057F\0040\0057PID\0040\0045\0045i\r\nFOR\0040\0057F\0040\0042tokens\00752\0040delims\0075\0072\0042\0040\0045\0045i\0040in\0040\0050\0047SC\0040QUERYEX\0040UmRdpService\0040\0136\0174FINDSTR\0040\0057I\0040\0042PID\0042\0047\0051\0040do\0040TASKKILL\0040\0057F\0040\0057PID\0040\0045\0045i\r\nSC\0040START\0040TermService\r\n\r\n" >>'/tmp/boot/net.tmp';
    }
      echo -ne "\0100ECHO\0040OFF\r\n\r\ncd\0056\0076\0045WINDIR\0045\0134GetAdmin\r\nif\0040exist\0040\0045WINDIR\0045\0134GetAdmin\0040\0050del\0040\0057f\0040\0057q\0040\0042\0045WINDIR\0045\0134GetAdmin\0042\0051\0040else\0040\0050\r\necho\0040CreateObject\0136\0050\0042Shell\0056Application\0042\0136\0051\0056ShellExecute\0040\0042\0045\0176s0\0042\0054\0040\0042\0045\0052\0042\0054\0040\0042\0042\0054\0040\0042runas\0042\0054\00401\0040\0076\0076\0040\0042\0045temp\0045\0134Admin\0056vbs\0042\r\n\0042\0045temp\0045\0134Admin\0056vbs\0042\r\ndel\0040\0057f\0040\0057q\0040\0042\0045temp\0045\0134Admin\0056vbs\0042\r\nexit\0040\0057b\00402\0051\r\n\r\n" >'/tmp/boot/net.tmp';
      [[ "$setNet" == '1' ]] && WinNoDHCP;
      [[ "$setNet" == '0' ]] && [[ "$AutoNet" == '0' ]] && WinNoDHCP;
      [[ "$setRDP" == '1' ]] && [[ -n "$WinRemote" ]] && WinRDP
      echo -ne "ECHO\0040SELECT\0040VOLUME\0075\0045\0045SystemDrive\0045\0045\0040\0076\0040\0042\0045SystemDrive\0045\0134diskpart\0056extend\0042\r\nECHO\0040EXTEND\0040\0076\0076\0040\0042\0045SystemDrive\0045\0134diskpart\0056extend\0042\r\nSTART\0040/WAIT\0040DISKPART\0040\0057S\0040\0042\0045SystemDrive\0045\0134diskpart\0056extend\0042\r\nDEL\0040\0057f\0040\0057q\0040\0042\0045SystemDrive\0045\0134diskpart\0056extend\0042\r\n\r\n" >>'/tmp/boot/net.tmp';
      echo -ne "cd\0040\0057d\0040\0042\0045ProgramData\0045\0057Microsoft\0057Windows\0057Start\0040Menu\0057Programs\0057Startup\0042\r\ndel\0040\0057f\0040\0057q\0040net\0056bat\r\n\r\n\r\n" >>'/tmp/boot/net.tmp';
      iconv -f 'UTF-8' -t 'GBK' '/tmp/boot/net.tmp' -o '/tmp/boot/net.bat'
      rm -rf '/tmp/boot/net.tmp'
    }

    [[ "$ddMode" == '0' ]] && {
      sed -i '/anna-install/d' /tmp/boot/preseed.cfg
      sed -i 's/wget.*\/sbin\/reboot\;\ //g' /tmp/boot/preseed.cfg
    }

    elif [[ "$linux_relese" == 'centos' ]]; then
    cat >/tmp/boot/ks.cfg<<EOF
    #platform=x86, AMD64, or Intel EM64T
    firewall --enabled --ssh
    install
    url --url="$LinuxMirror/$DIST/os/$VER/"
    rootpw --iscrypted $myPASSWORD
    auth --useshadow --passalgo=sha512
    firstboot --disable
    lang en_US
    keyboard us
    selinux --disabled
    logging --level=info
    reboot
    text
    unsupported_hardware
    vnc
    skipx
    timezone --isUtc Asia/Hong_Kong
    #ONDHCP network --bootproto=dhcp --onboot=on
    network --bootproto=static --ip=$IPv4 --netmask=$MASK --gateway=$GATE --nameserver=$ipDNS --onboot=on
    bootloader --location=mbr --append="rhgb quiet crashkernel=auto"
    zerombr
    clearpart --all --initlabel 
    autopart

    %packages
    @base
    %end

    %post --interpreter=/bin/bash
    rm -rf /root/anaconda-ks.cfg
    rm -rf /root/install.*log
    %end

    EOF


    [[ "$UNKNOWHW" == '1' ]] && sed -i 's/^unsupported_hardware/#unsupported_hardware/g' /tmp/boot/ks.cfg
    [[ "$(echo "$DIST" |grep -o '^[0-9]\{1\}')" == '5' ]] && sed -i '0,/^%end/s//#%end/' /tmp/boot/ks.cfg
    fi

    [[ -f /tmp/bootconf.sh ]] && cp -f /tmp/bootconf.sh /tmp/boot/bootconf.sh
    find . | cpio -H newc --create --verbose | gzip -9 > /tmp/initrd.img;
    cp -f /tmp/initrd.img /boot/initrd.img || sudo cp -f /tmp/initrd.img /boot/initrd.img
    cp -f /tmp/vmlinuz /boot/vmlinuz || sudo cp -f /tmp/vmlinuz /boot/vmlinuz

    chown root:root $GRUBDIR/$GRUBFILE
    chmod 444 $GRUBDIR/$GRUBFILE

    if [[ "$loaderMode" == "0" ]]; then
      sleep 3 && reboot || sudo reboot >/dev/null 2>&1
    else
      rm -rf "$HOME/loader"
      mkdir -p "$HOME/loader"
      cp -rf "/boot/initrd.img" "$HOME/loader/initrd.img"
      cp -rf "/boot/vmlinuz" "$HOME/loader/vmlinuz"
      [[ -f "/boot/initrd.img" ]] && rm -rf "/boot/initrd.img"
      [[ -f "/boot/vmlinuz" ]] && rm -rf "/boot/vmlinuz"
      echo && ls -AR1 "$HOME/loader"
    fi


}
