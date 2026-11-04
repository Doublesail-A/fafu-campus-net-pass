# 部署教程

## 先确认适用环境

本版适用于已经能管理的 OpenWrt / Kwrt 路由器，使用 nftables/fw4，且安装 nginx+uWSGI 版 LuCI。路由器 LAN 是 `172.31.255.1/24`、设备名 `br-lan`。建议使用网线维护并保留一个 SSH 窗口。

本仓库不包含校园网账号，也不会替换 WAN 拨号/校园认证程序。先按学校提供的方式完成上游接入，确认**路由器本机**可以访问互联网，再部署设备接入控制。上游认证流程不一样时，参考项目能帮助理解原理，但账户、认证地址和参数必须现场核对。

测试环境：aarch64、约512MB内存，sing-box 1.14.0、Squid 7.1、UA3F 3.6.0、dnsmasq-full 2.93，LuCI/rpcd、nginx 1.26.3、uWSGI 2.0.30。不同固件软件包名称可能不同。

## 1. 准备依赖

在路由器的软件包页面安装依赖，或在 SSH 执行下面的示例。软件源应与当前固件内核、架构完全匹配；缺包时使用相应项目的官方构建，不要混装其他固件的 kmod。

```sh
opkg update
opkg install squid sing-box ua3f dnsmasq-full openssl-util curl ip-full flock \
  lua liblua libubox-lua liblucihttp-lua luci-base rpcd rpcd-mod-file \
  nginx-ssl nginx-mod-luci nginx-mod-ubus uwsgi uwsgi-cgi-plugin uwsgi-luci-support
```

Clash YAML 导入还需要 `lyaml` 模块（部分固件包名为 `lua-lyaml`）。安装前可用 `lua -e 'require("lyaml")'` 检查。已有 dnsmasq 的固件升级 dnsmasq-full 可能存在包冲突，请通过固件包管理器按其提示处理；安装脚本不会强制卸载系统包。

## 2. 下载并上传代码

在 GitHub 仓库点击 **Code → Download ZIP**，解压到电脑。私有仓库需要先登录自己的 GitHub 账户。

Windows PowerShell 示例（目录名以实际解压结果为准）：

```powershell
scp -O -r .\fafu-campus-net-pass-main root@172.31.255.1:/tmp/fafu-campus-net-pass
ssh root@172.31.255.1
```

输入你自己的路由器密码。也可以用 WinSCP 上传文件夹到 `/tmp/fafu-campus-net-pass`。不需要把路由器密码、订阅或密钥写进 GitHub。

## 3. 先运行只读预检查

```sh
cd /tmp/fafu-campus-net-pass
sh install.sh --check
```

预检查会核对命令、Lua 模块、LuCI 的 uWSGI socket、LAN 地址和 Squid UID，并显示当前默认上游。缺什么先补什么；显示“预检查通过”才继续。

如果上游设备不是 `eth0`，在安装前编辑 `rootfiles/etc/config/privacy_stack` 中的 `wan_device`。LAN 地址、掩码或桥接名不同，应先适配各配置中的监听地址、CGI Host 检查、门户 DNS 与 nft 规则，不能只改一个变量。

## 4. 选择首次安装或升级

首次安装：

```sh
sh install.sh --apply
```

已有本仓库同架构透传方案：

```sh
sh install.sh --upgrade
```

安装会生成本机随机密钥、建立备份、检查服务配置并启用管理功能。升级保留现有设备、OTP 与代理设置，不覆盖现有 Squid/DNS 基础配置；但代理核心可能短暂重载。安装脚本不会更改路由器 LAN/WAN 地址、校园账号或 Wi-Fi 密码。

备份位于 `/root/fafu-install-日期时间/`。包含敏感配置，不要上传。失败时脚本调用回滚；完整恢复语义见恢复文档。

Squid 的 TLS 拦截监听语法需要一份本地 PEM，脚本只在路由器上生成它。它不用于签发网站证书，也不需要分发或安装到手机。新方案不提供证书下载流程。

## 5. 首次授权自己的管理设备

管理后台仍允许 LAN 访问，但未授权设备不能访问外网。在后台手工添加自己电脑的 MAC，或者先在 SSH 执行：

```sh
/usr/sbin/privacy-access add '02:00:00:00:00:01' '我的管理电脑' normal 1
```

**把示例 MAC 换成你自己当前网卡在该网络使用的 MAC。** 随机地址也可以登记；以后换地址需要重新登记。不要照抄示例，否则不会给真实设备授权。

## 6. 打开管理页面

- 设备与 OTP：`http://172.31.255.1/cgi-bin/luci/admin/network/privacy_access`
- 节点与分流：`http://172.31.255.1/cgi-bin/luci/admin/network/privacy_proxy`
- 自助登记：`http://172.31.255.1:8085/`

在“自助注册 / TOTP”配置中，用手机认证器扫码或输入新生成的密钥。设备登记时只需输入6位动态码；同一码只允许一次成功注册，其他设备等下一轮。首先确保路由器时间正确，否则验证码会失败。

## 7. 导入节点

打开“代理与临时分流”，上传 FlClash/Clash 的本地配置文件；无后缀也可以。先预览支持节点数和证书验证设置，再确认导入。只读取节点和可选规则，不执行脚本，也不采用文件中的端口、TUN、DNS 或外部 provider。

首次未导入节点时，普通设备与 IoT 可直连，代理入口保持拒绝。节点导入成功后再给设备设置“规则 / 全局”。如果需要规则模式，点击更新国内规则，使 `geosite-cn.srs`、`geoip-cn.srs` 就绪。首次获取规则需要可用节点及外网连接。

## 8. 验收

先用一台未授权设备验证无法访问外网；授权后验证 HTTPS 没有路由器 CA 提示；撤权后再验证被阻断。给一台设备设置规则代理，检查国内和境外目标；给 IoT 分组检查云连接。

测试代码：

```sh
sh scripts/check-source.sh
```

这里包含独立命名空间的权限与路由测试、TOTP 与解析器测试。新机整套初始化和各种硬件的冷启动还没有全部验证；先保留原系统备份，再做小范围试用。不要通过关闭证书验证来处理网页证书报错。
