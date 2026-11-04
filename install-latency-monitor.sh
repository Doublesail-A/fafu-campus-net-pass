#!/bin/sh
set -eu
umask 077
stage="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
state=/etc/privacy-latency-monitor
[ ! -e "$state/end" ] || { echo 'Monitor already configured; inspect existing state first';exit 1; }
command -v ip >/dev/null;command -v curl >/dev/null;command -v flock >/dev/null
[ "$(uci -q get dhcp.lan.start)" = 100 ] && [ "$(uci -q get dhcp.lan.limit)" = 150 ] || { echo 'Review probe .250 against DHCP pool before installing';exit 1; }
! uci -q show privacy_access | grep -qi '12:00:00:fe:ff:f4'
! ip neigh show 172.31.255.250 dev br-lan | grep -q lladdr
! ping -c 1 -W 1 172.31.255.250 >/dev/null 2>&1
mkdir -p "$state";chmod 700 "$state"
cp /etc/crontabs/root "$state/cron-before"
cp "$stage/rootfiles/usr/sbin/privacy-latency-monitor" /usr/sbin/privacy-latency-monitor
cp "$stage/rootfiles/usr/share/privacy-access/monitor-row.lua" /usr/share/privacy-access/monitor-row.lua
chmod 755 /usr/sbin/privacy-latency-monitor
sh -n /usr/sbin/privacy-latency-monitor
printf '%s\n' \
 'bilibili https://www.bilibili.com/' \
 'bili-api https://api.bilibili.com/x/web-interface/nav' \
 'bili-cdn https://s1.hdslb.com/bfs/seed/log/report/log-reporter.js' \
 'github https://github.com/' > "$state/targets"
now="$(date +%s)";printf '%s\n' "$now" > "$state/start";printf '%s\n' "$((now+172800))" > "$state/end"
/usr/sbin/privacy-access add '12:00:00:fe:ff:f4' '[监测]两天网络质量探针' normal 1 >/dev/null
printf '%s\n' '*/10 * * * * /usr/sbin/privacy-latency-monitor sample >/dev/null 2>&1 # privacy-latency-monitor' >> /etc/crontabs/root
/etc/init.d/cron reload
echo "48-hour monitor installed. Root-only logs: $state/log.jsonl"
