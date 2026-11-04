#!/bin/sh
set -e
stage="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
testdir="$(mktemp -d /tmp/privacy-status-test.XXXXXX)"
table="privacy_status_test_$$"
cleanup() { nft delete table inet "$table" 2>/dev/null || true; case "$testdir" in /tmp/privacy-status-test.?*) rm -rf "$testdir" ;; esac; }
trap cleanup EXIT
mkdir "$testdir/config" "$testdir/discovery"
cp "$stage/rootfiles/etc/config/privacy_access" "$testdir/config/privacy_access"
export UCI_CONFIG_DIR="$testdir/config" PA_LIBRARY="$stage/rootfiles/usr/share/privacy-access/common.sh"
export PA_CLASSIFIER="$stage/rootfiles/etc/privacy-classify.sh" PA_DISCOVERY="$stage/rootfiles/usr/share/privacy-access/discovery.sh"
export PA_DISCOVERY_FIXTURE="$testdir/discovery" PA_LEASES="$testdir/leases"
export PA_POLICY_TABLE="$table" PA_IOT_TABLE="$table" PA_MITM_TABLE="$table"
export PA_LOCK="$testdir/classify.lock" PA_WRITE_LOCK="$testdir/write.lock"
cli="$stage/rootfiles/usr/sbin/privacy-access"
chmod 755 "$cli" "$PA_CLASSIFIER"
future="$(($(date +%s) + 3600))"
printf '%s 02:00:00:00:00:88 10.77.0.88 gaming-pc *\n%s 02:00:00:00:00:99 10.77.0.99 lease-only *\n%s 02:00:00:00:00:dd 10.77.0.77 offline-phone *\n' "$future" "$future" "$future" > "$PA_LEASES"
printf 'S 02:00:00:00:00:88 phy1-ap0\nS 02:00:00:00:00:aa phy0-ap0\nN 02:00:00:00:00:aa 10.77.0.22 REACHABLE\nF 02:00:00:00:00:cc wired 2\nF 02:00:00:00:00:99 wifi 1\n' > "$testdir/discovery/events"
printf 'table inet %s {\nset allowed_macs { type ether_addr; }\nset normal_macs { type ether_addr; }\nset iot_macs { type ether_addr; }\n}\n' "$table" | nft -f -
"$cli" add 02:00:00:00:00:88 '游戏电脑备注' normal 1 '' '测试人员' >/dev/null
"$cli" add 02:00:00:00:00:cc '停用设备' normal 0 >/dev/null
"$cli" add 02:00:00:00:00:dd '离线手机备注' normal 1 >/dev/null
"$cli" list > "$testdir/status.json"
query() { jsonfilter -i "$testdir/status.json" -e "$1"; }
[ "$(query '@.devices[@.mac="02:00:00:00:00:88"].hostname')" = 'gaming-pc' ]
[ "$(query '@.devices[@.mac="02:00:00:00:00:88"].remark')" = '游戏电脑备注' ]
[ "$(query '@.devices[@.mac="02:00:00:00:00:88"].owner')" = '测试人员' ]
[ "$(query '@.devices[@.mac="02:00:00:00:00:88"].connected')" = 'true' ]
[ "$(query '@.devices[@.mac="02:00:00:00:00:dd"].connected')" = 'false' ]
[ "$(query '@.devices[@.mac="02:00:00:00:00:cc"].connected')" = 'true' ]
[ "$(query '@.unregistered[0].mac')" = '02:00:00:00:00:aa' ]
[ "$(query '@.unregistered[0].ips[0]')" = '10.77.0.22' ]
[ "$(query '@.unregistered[*].mac' | wc -l)" -eq 1 ]
# Imported duplicate section names must also be replaced, not only canonical names.
uci -q -c "$UCI_CONFIG_DIR" set privacy_access.old_alias=device
uci -q -c "$UCI_CONFIG_DIR" set privacy_access.old_alias.mac=02-00-00-00-00-88
uci -q -c "$UCI_CONFIG_DIR" set privacy_access.old_alias.enabled=1
uci -q -c "$UCI_CONFIG_DIR" commit privacy_access
"$cli" add 02-00-00-00-00-88 '新的备注' iot 0 >/dev/null
[ "$(uci -q -c "$UCI_CONFIG_DIR" get privacy_access.mac_020000000088.name)" = '新的备注' ]
[ "$(uci -q -c "$UCI_CONFIG_DIR" get privacy_access.mac_020000000088.group)" = iot ]
[ "$(uci -q -c "$UCI_CONFIG_DIR" get privacy_access.mac_020000000088.enabled)" = 0 ]
[ "$(uci -q -c "$UCI_CONFIG_DIR" get privacy_access.mac_020000000088.owner)" = '测试人员' ]
"$cli" add 02:00:00:00:00:88 '新的备注' iot 0 '' '' >/dev/null
[ -z "$(uci -q -c "$UCI_CONFIG_DIR" get privacy_access.mac_020000000088.owner)" ]
if "$cli" add 02:00:00:00:00:88 '新的备注' iot 0 '' "$(printf 'bad\towner')" >/dev/null 2>&1; then exit 1; fi
if uci -q -c "$UCI_CONFIG_DIR" get privacy_access.old_alias >/dev/null; then exit 1; fi
"$cli" list > "$testdir/status.json"
[ "$(query '@.devices[@.mac="02:00:00:00:00:88"].allowed')" = false ]
printf '%s\n' 'PASS: names/remarks separated; Wi-Fi and wired presence; lease-only is offline; static-IP unknown client; duplicate MAC replacement and disabled permission.'

# Real UCI transactions; metadata operations must not modify permissions or nft.
uci -q -c "$UCI_CONFIG_DIR" export privacy_access | sed '/option owner /d;/list owners /d' > "$testdir/security.before"
nft list table inet "$table" > "$testdir/nft.before"
"$cli" people-add '测试空组' >/dev/null
"$cli" people-add '第二组' >/dev/null
if "$cli" people-add '测试空组' >/dev/null 2>&1;then exit 1;fi
"$cli" list > "$testdir/status.json"
[ "$(query '@.owners[*]' | wc -l)" -eq 2 ]
"$cli" people-move '测试空组' 02:00:00:00:00:88 02:00:00:00:00:dd >/dev/null
"$cli" people-rename '测试空组' '已改名' >/dev/null
[ "$(uci -q -c "$UCI_CONFIG_DIR" get privacy_access.mac_020000000088.owner)" = '已改名' ]
[ "$(uci -q -c "$UCI_CONFIG_DIR" get privacy_access.mac_0200000000dd.owner)" = '已改名' ]
if "$cli" people-move '第二组' 02:00:00:00:00:88 02:00:00:00:00:ef >/dev/null 2>&1;then exit 1;fi
[ "$(uci -q -c "$UCI_CONFIG_DIR" get privacy_access.mac_020000000088.owner)" = '已改名' ]
if "$cli" people-move '不存在' 02:00:00:00:00:88 >/dev/null 2>&1;then exit 1;fi
if "$cli" people-rename '已改名' '第二组' >/dev/null 2>&1;then exit 1;fi
if "$cli" people-add "$(printf 'bad\towner')" >/dev/null 2>&1;then exit 1;fi
uci -q -c "$UCI_CONFIG_DIR" set privacy_access.main.pending_test='must-remain'
if "$cli" people-add '不能提交别人的修改' >/dev/null 2>&1;then exit 1;fi
[ "$(uci -q -c "$UCI_CONFIG_DIR" get privacy_access.main.pending_test)" = 'must-remain' ]
uci -q -c "$UCI_CONFIG_DIR" revert privacy_access
"$cli" people-remove '已改名' >/dev/null
[ -z "$(uci -q -c "$UCI_CONFIG_DIR" get privacy_access.mac_020000000088.owner)" ]
"$cli" people-move '' 02:00:00:00:00:dd >/dev/null
"$cli" people-remove '第二组' >/dev/null
uci -q -c "$UCI_CONFIG_DIR" export privacy_access | sed '/option owner /d;/list owners /d' > "$testdir/security.after"
cmp "$testdir/security.before" "$testdir/security.after"
nft list table inet "$table" > "$testdir/nft.after"
cmp "$testdir/nft.before" "$testdir/nft.after"
printf '%s\n' 'PASS people: real UCI empty groups, create/rename/delete, batch move, atomic validation, pending UCI preservation, unchanged authorization fields and nft.'
