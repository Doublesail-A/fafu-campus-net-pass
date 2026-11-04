#!/bin/sh
set -eu
failed=0
for cmd in lua nft sing-box squid openssl nginx uci jsonfilter flock ip curl pgrep;do
 if ! command -v "$cmd" >/dev/null 2>&1;then echo "缺少命令：$cmd";failed=1;fi
done
lua -e 'require("nixio.fs");require("luci.jsonc");require("luci.sys");require("luci.util");require("lyaml")' || failed=1
for file in /usr/share/libubox/jshn.sh /etc/init.d/ua3f /etc/nginx/uci.conf /var/run/luci-webui.socket;do
 [ -e "$file" ] || { echo "缺少运行环境：$file";failed=1; }
done
[ "$(uci -q get network.lan.ipaddr)" = '172.31.255.1' ] || { echo '本版要求LAN地址172.31.255.1，请先阅读部署说明';failed=1; }
ip link show br-lan >/dev/null 2>&1 || { echo '需要br-lan';failed=1; }
id nobody >/dev/null 2>&1 || failed=1
[ "$(id -u nobody)" = '65534' ] || { echo '请审核Squid UID优化规则后再安装';failed=1; }
echo "默认上游：$(ip -4 route show default | head -1)"
sing-box version | head -1
[ "$failed" = 0 ] || exit 1
echo '预检查通过。尚未修改系统。'
