# 一键DD脚本

## 注意

全自动安装默认ROOT密码:```haoduck.com```  

支持自定义ROOT密码、SSH端口(Linux)  

特别注意:OpenVZ构架不适用.

## 傻瓜式一键脚本
```
curl -sSL -k -o dd.sh https://raw.githubusercontent.com/ZhuangJiayu/dd/master/dd.sh && chmod +x dd.sh && bash dd.sh
```

```
curl -sSL -k -o dd.sh https://fastly.jsdelivr.net/gh/ZhuangJiayu/dd@latest/dd.sh && chmod +x dd.sh && bash dd.sh
```

## 支持镜像

- Debian 13 / 12 / 11 / 10（网络安装，自定义密码/端口）
- Ubuntu 20.04 / 18.04 / 16.04（网络安装，自定义密码/端口）
- CentOS 6（网络安装，自定义密码/端口）
- CentOS 7.8 / 7.6、Rocky Linux 8.6（dd 模式，自定义密码/端口）
- 选项 100 自定义直链：可 dd 任意镜像（包括 Windows，如 Windows 官方/第三方 vhd.gz 直链）

## Tip

谷歌云GCP使用时需要把掩码手动改为255.255.255.0


部分代码copy自 https://github.com/veip007/dd 以及 https://github.com/hiCasper/Shell 。特别感谢 https://github.com/haoduck/dd 主要是添加了自定义ROOT密码和SSH端口，有现成的代码就偷懒了。
