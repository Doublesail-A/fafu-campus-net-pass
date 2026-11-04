#!/bin/sh
set -eu
base="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
case "$base" in /root/fafu-install-*) ;;*)exit 1;;esac
touch /tmp/privacy-transport-maintenance
umask 077
tar -czpf "$base/etc-at-rollback.tar.gz" -C / etc
for service in privacy-services privacy-squid privacy-doh privacy-relay-compat privacy-register-dns privacy-policy iot-proxy ua3f;do
 if [ -x "/etc/init.d/$service" ];then "/etc/init.d/$service" stop >/dev/null 2>&1 || true;"/etc/init.d/$service" disable >/dev/null 2>&1 || true;fi
done
while IFS= read -r path;do
 case "$path" in /*|*'..'*)exit 1;;esac
 rm -f "/$path"
done < "$base/new-files"
tar -xzpf "$base/etc-before.tar.gz" -C /
while IFS= read -r path;do
 case "$path" in /*|*'..'*)exit 1;;esac
 case "$path" in etc/*)continue;;esac
 cp -p "$base/files/$path" "/$path"
done < "$base/old-files"
nft list table inet privacy_wire_profile >/dev/null 2>&1 && nft delete table inet privacy_wire_profile || true
if [ -x /etc/privacy-classify.sh ];then /etc/privacy-classify.sh --replace;fi
for service in ua3f iot-proxy privacy-policy privacy-register-dns privacy-doh privacy-relay-compat;do
 if [ -x "/etc/init.d/$service" ] && "/etc/init.d/$service" enabled;then "/etc/init.d/$service" start >/dev/null 2>&1 || true;fi
done
for service in dnsmasq nginx rpcd sysntpd cron;do "/etc/init.d/$service" reload >/dev/null 2>&1 || true;done
squid -k reconfigure >/dev/null 2>&1 || true
rm -f /tmp/privacy-transport-maintenance
echo "已恢复安装前/etc配置和程序。回滚时的全部配置另存$base/etc-at-rollback.tar.gz。"
