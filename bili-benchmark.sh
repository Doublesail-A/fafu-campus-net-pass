#!/bin/sh
set -eu
umask 077
stage="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)";label="$1"
case "$label" in *[!a-zA-Z0-9_-]*)exit 1;;esac
b=/root/privacy-webperf-20261102;out="$b/$label";mkdir -p "$out"
ns="bw_$$";dev="bwd$$";peer="bwp$$";mac='12:00:00:fe:ff:ec';addr=172.31.255.248;added=0
cleanup(){
 code=$?;[ "$added" = 0 ] || /usr/sbin/privacy-access remove "$mac" >/dev/null 2>&1 || true
 ip link del "$dev" 2>/dev/null || true;ip netns del "$ns" 2>/dev/null || true;ip neigh del "$addr" dev br-lan 2>/dev/null || true
 case "$ns" in bw_[0-9]*)rm -f "/etc/netns/$ns/resolv.conf";rmdir "/etc/netns/$ns" 2>/dev/null || true;;esac
 echo "BENCH_EXIT=$code"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
! uci -q show privacy_access | grep -qi "$mac"
if ip neigh show "$addr" dev br-lan | grep -q lladdr || ping -c 1 -W 1 "$addr" >/dev/null 2>&1;then exit 1;fi
ip netns add "$ns";ip link add "$dev" type veth peer name "$peer";ip link set "$peer" netns "$ns";ip link set "$dev" master br-lan;ip link set "$dev" up
ip -n "$ns" link set lo up;ip -n "$ns" link set "$peer" address "$mac";ip -n "$ns" addr add "$addr/24" dev "$peer";ip -n "$ns" link set "$peer" up;ip -n "$ns" route add default via 172.31.255.1
mkdir -p "/etc/netns/$ns";printf 'nameserver 172.31.255.1\n' > "/etc/netns/$ns/resolv.conf"
/usr/sbin/privacy-access add "$mac" 'Disposable Bilibili benchmark' normal 1 >/dev/null;added=1
date '+START %H:%M:%S'
for parallel in ${BENCH_LEVELS:-1 6 12};do
 for round in 1 2;do
  run="$out/p$parallel-r$round";mkdir -p "$run"
  cat /proc/stat > "$run/cpu-before";cat /proc/$(pidof ua3f)/stat > "$run/ua-before"
  nft list chain inet UA3F privacy_output > "$run/nft-before"
  cut -d' ' -f1 /proc/uptime > "$run/start"
  index=0;pids='';pending=0
  while IFS= read -r url;do
   index=$((index+1));pending=$((pending+1))
   ip netns exec "$ns" curl --noproxy '*' --compressed --http2 --connect-timeout 4 --max-time 12 -sS -L -o /dev/null -e https://www.bilibili.com/ -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36' -w '%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{http_version}\n' "$url" > "$run/$index.txt" 2> "$run/$index.err" & pids="$pids $!"
   if [ "$pending" -ge "$parallel" ];then for pid in $pids;do wait "$pid" || true;done;pids='';pending=0;fi
  done < "$stage/bili-resources.txt"
  for pid in $pids;do wait "$pid" || true;done
  cut -d' ' -f1 /proc/uptime > "$run/end"
  cat /proc/$(pidof ua3f)/stat > "$run/ua-after"
  nft list chain inet UA3F privacy_output > "$run/nft-after"
  lua "$stage/bili-summary.lua" "$run"
 done
done
/usr/sbin/privacy-access remove "$mac" >/dev/null;added=0
sha256sum -c "$b/invariants"
date '+END %H:%M:%S'
