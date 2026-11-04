#!/bin/sh
set -eu
umask 077
base="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
mode="${1:---check}"
case "$mode" in --check|--apply|--upgrade);;*)echo '用法：sh install.sh --check|--apply|--upgrade';exit 2;;esac
sh "$base/scripts/preflight.sh"
[ "$mode" != --check ] || exit 0
[ "$(id -u)" = 0 ] || exit 1
if [ "$mode" = --apply ];then
 [ ! -f /etc/config/privacy_access ] || { echo '已有配置，请使用--upgrade；不会覆盖现有白名单';exit 1; }
else
 grep -qx tls-passthrough-v1 /etc/privacy-transport-mode || { echo '只支持从同架构透传版升级';exit 1; }
fi
stamp="$(date +%Y%m%d-%H%M%S)";backup="/root/fafu-install-$stamp"
mkdir -p "$backup";chmod 700 "$backup"
tar -czpf "$backup/etc-before.tar.gz" -C / etc
find "$base/rootfiles" -type f | sed "s@$base/rootfiles/@@" > "$backup/managed-files"
printf '%s\n' etc/privacy-transport-mode etc/privacy-proxy/settings.json etc/privacy-proxy/devices etc/privacy-proxy/api.secret etc/sing-box/privacy-iot.json etc/privacy-registration.secret etc/privacy-registration.last-step etc/squid/ca.pem >> "$backup/managed-files"
sort -u "$backup/managed-files" > "$backup/managed-sorted";mv "$backup/managed-sorted" "$backup/managed-files"
: > "$backup/old-files";: > "$backup/new-files"
while IFS= read -r path;do
 if [ -f "/$path" ];then mkdir -p "$backup/files/$(dirname "$path")";cp -p "/$path" "$backup/files/$path";echo "$path" >> "$backup/old-files";else echo "$path" >> "$backup/new-files";fi
done < "$backup/managed-files"
cp "$base/scripts/rollback-install.sh" "$backup/rollback.sh";chmod 700 "$backup/rollback.sh"
touch /tmp/privacy-transport-maintenance
trap 'code=$?;if [ "$code" != 0 ];then sh "$backup/rollback.sh";fi;exit "$code"' EXIT
while IFS= read -r path;do
 [ -f "$base/rootfiles/$path" ] || continue
 case "$path" in
  etc/config/privacy_access|etc/config/privacy_stack) [ ! -e "/$path" ] || continue;;
  etc/squid/*) [ "$mode" = --apply ] || continue;;
  etc/sing-box/privacy-doh.json|etc/init.d/privacy-doh|etc/init.d/privacy-squid|etc/init.d/privacy-relay-compat|usr/sbin/privacy-services-watchdog) [ "$mode" = --apply ] || continue;;
 esac
 mkdir -p "/$(dirname "$path")";cp "$base/rootfiles/$path" "/$path"
 chmod 644 "/$path"
 case "$path" in etc/init.d/*|usr/sbin/*|etc/privacy-classify.sh|www/cgi-bin/*)chmod 755 "/$path";;esac
done < "$backup/managed-files"
chmod 600 /etc/config/privacy_access /etc/config/privacy_stack
printf '%s\n' tls-passthrough-v1 > /etc/privacy-transport-mode
chmod 600 /etc/privacy-transport-mode
lua "$base/scripts/bootstrap-state.lua"
. /usr/share/privacy-access/registration.sh
pa_reg_init
uci set privacy_access.main.registration_enabled='1';uci commit privacy_access
if [ "$mode" = --apply ];then
 mkdir -p /etc/squid
 # Squid's intercept listener requires a local PEM even for unconditional splice.
 # It is never distributed or used to sign origin certificates.
 if [ ! -s /etc/squid/ca.pem ];then
  openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=Local intercept listener/' -keyout "$backup/listener.key" -out "$backup/listener.crt" >/dev/null 2>&1
  cat "$backup/listener.key" "$backup/listener.crt" > /etc/squid/ca.pem;chmod 600 /etc/squid/ca.pem
 fi
 uci set ua3f.enabled='ua3f';uci set ua3f.enabled.enabled='1';uci set ua3f.main='main'
 uci set ua3f.main.server_mode='REDIRECT';uci set ua3f.main.port='1080';uci set ua3f.main.bind='127.0.0.1';uci set ua3f.main.mitm_enabled='0';uci set ua3f.main.rewrite_mode='GLOBAL'
 uci set ua3f.main.ua="$(uci -q get privacy_stack.main.ua)";uci commit ua3f
 /etc/init.d/ua3f enable;/etc/init.d/ua3f restart
 /etc/init.d/privacy-relay-compat enable;/etc/init.d/privacy-relay-compat start
 /etc/init.d/privacy-squid enable
 /etc/init.d/privacy-doh enable;/etc/init.d/privacy-doh start
 uci set dhcp.@dnsmasq[0].noresolv='1'
 uci -q delete dhcp.@dnsmasq[0].server || true
 uci add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#5353'
 uci add_list 'dhcp.@dnsmasq[0].server=223.5.5.5'
 uci set dhcp.@dnsmasq[0].strictorder='1'
else
 /usr/sbin/privacy-proxy init
fi
sing-box check -c /etc/sing-box/privacy-iot.json
squid -k parse -f /etc/squid/squid.conf > "$backup/squid-parse.log" 2>&1
! grep -q 'ERROR:' "$backup/squid-parse.log"
dnsmasq --test --conf-file=/etc/privacy-register-dns.conf
nginx -t -c /etc/nginx/uci.conf
uci set dhcp.@dnsmasq[0].filter_aaaa='1';uci commit dhcp
uci set system.ntp.enable_server='1';uci commit system
/etc/init.d/dnsmasq reload
/etc/init.d/sysntpd restart
/etc/init.d/privacy-policy enable;/etc/privacy-classify.sh --replace
/etc/init.d/iot-proxy enable;/etc/init.d/iot-proxy restart
if [ "$mode" = --apply ];then /etc/init.d/privacy-squid start;fi
/etc/init.d/privacy-register-dns enable;/etc/init.d/privacy-register-dns restart
/etc/init.d/nginx reload;/etc/init.d/rpcd restart
if [ "$mode" = --apply ];then
 printf '%s\n' '* * * * * /usr/sbin/privacy-services-watchdog >/dev/null 2>&1 # fafu-services' >> /etc/crontabs/root
fi
/etc/init.d/cron reload
rm -f /tmp/privacy-transport-maintenance
trap - EXIT
echo "安装完成。备份：$backup；回滚：sh $backup/rollback.sh"
echo '管理入口：http://172.31.255.1/cgi-bin/luci/admin/network/privacy_access'
echo '代理入口：http://172.31.255.1/cgi-bin/luci/admin/network/privacy_proxy'
echo '首先授权自己的MAC或在后台配置TOTP；节点需自行导入。'
