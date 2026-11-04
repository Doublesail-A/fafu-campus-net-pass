# 致谢与第三方组件

## 方案参考

[YifanHere/campus-net-nat-bypass](https://github.com/YifanHere/campus-net-nat-bypass/) 为本项目提供了重要帮助，特别是：

- 全TCP重新发起与仅修改TTL/NAT之间的区别，尤其不能遗漏443。
- DNS/NTP、IPv6与AAAA响应需要保持一致，避免既禁用IPv6又让终端长时间尝试IPv6。
- 透明REDIRECT会改变报文所经链路，访问边界和统计必须放在实际经过的位置。
- 应通过两侧抓包、会话与实际连通验证，不能只看配置文本。
- 掉线恢复应区分认证失败、暂时网络故障与风控等待，不应反复重启WAN。

这些思路帮助本项目从旧的HTTPS解密方案转向端到端TLS透传，同时保留TCP中继。本仓库不是该项目的官方分支，不包含其作者的校园账户或私人路由器脚本，也不把其对某校检测机制的判断推广成普遍结论。

## 组件

| 组件 | 用途与上游 |
| --- | --- |
| OpenWrt / LuCI / rpcd / nftables | [OpenWrt](https://openwrt.org/)、[LuCI](https://github.com/openwrt/luci)、[nftables](https://netfilter.org/projects/nftables/) |
| Squid | [Squid](https://www.squid-cache.org/) 的透明接入与splice |
| sing-box | [SagerNet/sing-box](https://github.com/SagerNet/sing-box) 的节点、规则、DNS与TCP中继 |
| UA3F | [sunbk201/UA3F](https://github.com/sunbk201/UA3F) 的HTTP UA处理与透明中继 |
| FlClash / mihomo | [chen08209/FlClash](https://github.com/chen08209/FlClash)、[MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) 的配置兼容与客户端对照 |
| nginx / uWSGI / dnsmasq / OpenSSL | Web接入、CGI、DNS与TOTP所需密码运算 |

第三方组件不在本仓库重新打包，安装、修改、再分发时应遵循各自许可。没有把对方README整篇复制进本仓库。

## 技术文档

- [Squid ssl_bump / splice](https://www.squid-cache.org/Doc/config/ssl_bump/)
- [sing-box route actions](https://sing-box.sagernet.org/configuration/route/rule_action/)
- [mihomo URLTest](https://wiki.metacubex.one/config/proxy-groups/url-test/)
- [mihomo统一延迟](https://wiki.metacubex.one/config/general/)
