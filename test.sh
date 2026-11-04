#!/bin/sh
# End-to-end packet tests in isolated network namespaces; no live clients affected.
# TLS here terminates at self-signed fixture Nginx listeners. Trust assertions
# validate the fixture, not a production requirement to install a router CA.
set -e
stage="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
testdir="$(mktemp -d /tmp/privacy-access-test.XXXXXX)"
r="pa_r_$$"; c="pa_c_$$"; w="pa_w_$$"
cleanup() {
    for ns in "$c" "$r" "$w"; do
        for pid in $(ip netns pids "$ns" 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
        ip netns delete "$ns" 2>/dev/null || true
    done
    case "$testdir" in /tmp/privacy-access-test.?*) rm -rf "$testdir" ;; esac
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir "$testdir/config"
cp "$stage/rootfiles/etc/config/privacy_access" "$testdir/config/privacy_access"
export UCI_CONFIG_DIR="$testdir/config"
export PA_LIBRARY="$stage/rootfiles/usr/share/privacy-access/common.sh"
export PA_CLASSIFIER="$stage/rootfiles/etc/privacy-classify.sh"
export PA_TEMPLATE="$stage/rootfiles/etc/privacy-policy.nft"
export PA_DISCOVERY="$stage/rootfiles/usr/share/privacy-access/discovery.sh"
export PA_LEASES="$testdir/leases"
export PA_TEMP_PROXY_FILE="$testdir/temporary"
export PA_POLICY_TABLE=privacy_policy PA_IOT_TABLE=iot_proxy PA_MITM_TABLE=fw4
export PA_LOCK="$testdir/classify.lock" PA_WRITE_LOCK="$testdir/write.lock"
cli="$stage/rootfiles/usr/sbin/privacy-access"
chmod 755 "$cli" "$PA_CLASSIFIER"
mac='02:00:00:00:00:88'
future="$(($(date +%s) + 3600))"
printf '%s %s %s %s\n' "$future" "$mac" '10.77.0.2' 'test-device' > "$PA_LEASES"
for ns in "$r" "$c" "$w"; do ip netns add "$ns"; ip -n "$ns" link set lo up; done
ip link add "pa_a$$" type veth peer name "pa_b$$"
ip link set "pa_a$$" netns "$c"; ip link set "pa_b$$" netns "$r"
ip -n "$c" link set "pa_a$$" name client0
ip -n "$c" link set client0 address "$mac"
ip -n "$r" link add br-lan type bridge
ip -n "$r" link set "pa_b$$" master br-lan
ip -n "$r" link set "pa_b$$" up
ip -n "$r" addr add 10.77.0.1/24 dev br-lan
ip -n "$r" link set br-lan up
ip -n "$c" addr add 10.77.0.2/24 dev client0
ip -n "$c" link set client0 up
ip -n "$c" route add default via 10.77.0.1
for pair in 'eth0 0' 'usb0 1'; do
    set -- $pair; iface="$1"; subnet="$2"
    ip link add "pa_x$$" type veth peer name "pa_y$$"
    ip link set "pa_x$$" netns "$r"; ip link set "pa_y$$" netns "$w"
    ip -n "$r" link set "pa_x$$" name "$iface"
    ip -n "$w" link set "pa_y$$" name "wan$subnet"
    ip -n "$r" addr add "198.18.$subnet.1/24" dev "$iface"
    ip -n "$w" addr add "198.18.$subnet.2/24" dev "wan$subnet"
    ip -n "$r" link set "$iface" up
    ip -n "$w" link set "wan$subnet" up
done
ip -n "$w" route add 10.77.0.0/24 via 198.18.0.1
ip netns exec "$r" sysctl -qw net.ipv4.ip_forward=1
printf 'pid %s/server.pid; error_log %s/server.log; events {} http { access_log off; server { listen 80; listen 443; location / { return 200 "EXTERNAL"; } } }\n' "$testdir" "$testdir" > "$testdir/server.conf"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$testdir/test.key" -out "$testdir/test.crt" -days 1 -subj /CN=privacy-access-test -addext 'subjectAltName=IP:198.18.0.2,IP:198.18.1.2' >/dev/null 2>&1
printf 'pid %s/router.pid; error_log %s/router.log; events {} http { access_log off; server { listen 3130 ssl; ssl_certificate %s/test.crt; ssl_certificate_key %s/test.key; location / { return 200 "NORMAL"; } } server { listen 3131 ssl; ssl_certificate %s/test.crt; ssl_certificate_key %s/test.key; location / { return 200 "TEMP_TLS"; } } server { listen 3132; location / { return 200 "TEMP_HTTP"; } } server { listen 7895; location / { return 200 "IOT"; } } server { listen 1080; listen 3129; location / { return 200 "PROXY"; } } server { listen 53; location / { return 200 "DNS"; } } server { listen 5354; location / { return 200 "CAPTIVE_DNS"; } } server { listen 8085; location / { return 200 "PORTAL"; } } server { listen 8080; location / { return 200 "ADMIN"; } } }\n' "$testdir" "$testdir" "$testdir" "$testdir" "$testdir" "$testdir" > "$testdir/router.conf"
sed -i 's/listen 7895;/listen 7894; listen 7895;/' "$testdir/router.conf"
sed -i 's/listen 1080; listen 3129;/listen 1080; listen 3129; listen 7897;/' "$testdir/router.conf"
ip netns exec "$w" nginx -c "$testdir/server.conf" -g 'daemon off;' &
ip netns exec "$r" nginx -c "$testdir/router.conf" -g 'daemon off;' &
sleep 1
apply() { ip netns exec "$r" "$PA_CLASSIFIER" "$@"; }
runcli() { ip netns exec "$r" "$cli" "$@"; }
fetch() { ip netns exec "$c" curl --noproxy '*' --connect-timeout 1 --max-time 2 -s "http://$1"; }
expect() {
    response="$(fetch "$1" || true)"
    [ "$response" = "$2" ] || { printf 'FAIL %s: expected %s, got %s\n' "$1" "$2" "$response" >&2; exit 1; }
}
expect_tls() {
    response="$(ip netns exec "$c" curl --noproxy '*' --cacert "$testdir/test.crt" --connect-timeout 2 --max-time 5 -s "https://$1")"
    [ "$response" = "${2:-NORMAL}" ] || { printf 'FAIL: trusted CA route %s\n' "$1" >&2; exit 1; }
}
blocked() {
    if fetch "$1" > "$testdir/blocked-output"; then printf 'FAIL: bypass %s\n' "$1" >&2; exit 1; fi
}
# Reproduce the old eth0-only IP gate: the secondary uplink and direct local
# proxy remain accessible to an IP absent from managed_clients.
ip netns exec "$r" nft -f - <<'NFT'
table inet privacy_policy {
    set managed_clients { type ipv4_addr; elements = { 10.77.0.2 }; }
    chain prerouting_gate {
        type filter hook prerouting priority -132; policy accept;
        iifname "br-lan" fib daddr oifname "eth0" ip saddr != @managed_clients counter drop
    }
    chain forward_gate {
        type filter hook forward priority -19; policy accept;
        iifname "br-lan" oifname "eth0" ip saddr != @managed_clients counter drop
    }
}
table inet iot_proxy {
    set iot_set { type ipv4_addr; elements = { 10.77.0.2 }; }
    chain prerouting {
        type nat hook prerouting priority -150; policy accept;
        iifname "br-lan" fib daddr oifname "eth0" ip saddr @iot_set meta l4proto tcp redirect to :7895
    }
}
NFT
printf 'flush set inet privacy_policy managed_clients\nflush set inet iot_proxy iot_set\n' | ip netns exec "$r" nft -f -
blocked 198.18.0.2:80
expect 198.18.1.2:80 EXTERNAL
expect 10.77.0.1:1080 PROXY
printf '%s\n' 'CONFIRMED: legacy gate blocks primary WAN but leaves secondary WAN and explicit local proxy accessible to unauthorized devices.'
# Seed obsolete exemptions in separate tables: strict apply must empty them.
printf 'table inet iot_proxy {\nset iot_set { type ipv4_addr; elements = { 10.77.0.2 }; }\n}\ntable inet fw4 {\nset privacy_mitm_bypass { type ipv4_addr; elements = { 10.77.0.2 }; }\n}\n' | ip netns exec "$r" nft -f -
apply --replace
expect 10.77.0.1:8080 ADMIN
expect 198.18.0.2:80 PORTAL
expect 198.18.1.2:80 PORTAL
blocked 10.77.0.1:1080
blocked 10.77.0.1:3130
expect 10.77.0.1:53 CAPTIVE_DNS
# A hostname containing mibt must not auto-authorize.
printf '%s %s %s %s\n' "$future" "$mac" '10.77.0.2' 'unauthorized_mibt' > "$PA_LEASES"
apply
blocked 198.18.0.2:443
runcli add '02-00-00-00-00-88' '测试 <tag> "quoted"' >/dev/null
expect 198.18.0.2:80 PROXY
expect 198.18.1.2:80 PROXY
expect 198.18.0.2:8088 PROXY
blocked 10.77.0.1:7897
expect_tls 198.18.0.2:443
expect_tls 198.18.1.2:443
expect 10.77.0.1:53 DNS
expect 198.18.1.2:53 DNS
# The same normal-group TLS connection must fail without the CA.
if ip netns exec "$c" curl --noproxy '*' --connect-timeout 1 --max-time 2 -s https://198.18.0.2 > "$testdir/no-ca"; then
    printf 'FAIL: normal group TLS passed without its CA\n' >&2; exit 1
fi
blocked 10.77.0.1:1080
# Unknown MAC using exactly the allowed static IP must still fail.
deny_before="$(ip netns exec "$r" nft list chain inet privacy_policy prerouting_gate | awk '/deny unknown MAC/ {for(i=1;i<=NF;i++)if($i=="packets")print $(i+1)}')"
ip -n "$c" link set client0 address 02:00:00:00:00:99
expect 198.18.0.2:80 PORTAL
blocked 198.18.1.2:443
deny_after="$(ip netns exec "$r" nft list chain inet privacy_policy prerouting_gate | awk '/deny unknown MAC/ {for(i=1;i<=NF;i++)if($i=="packets")print $(i+1)}')"
[ "$deny_after" -gt "$deny_before" ] || { printf 'FAIL: spoofed-IP denial did not hit MAC guard\n' >&2; exit 1; }
ip -n "$c" link set client0 address "$mac"
# Expired/no DHCP lease does not revoke a known static-IP device.
printf '%s %s %s %s\n' 1 "$mac" '10.77.0.2' 'expired' > "$PA_LEASES"
apply
expect_tls 198.18.0.2:443
# IPv6 egress must not bypass the IPv4 certificate proxy.
printf '%s %s\n' "$mac" "$(($(date +%s)+20))" > "$PA_TEMP_PROXY_FILE"
apply
expect 198.18.0.2:80 TEMP_HTTP
expect_tls 198.18.0.2:443 TEMP_TLS
expect 198.18.1.2:8000 IOT
blocked 10.77.0.1:3131
blocked 10.77.0.1:3132
blocked 10.77.0.1:7894
if ip netns exec "$c" curl --noproxy '*' --connect-timeout 1 --max-time 2 -s https://198.18.0.2 >/dev/null; then printf 'FAIL: temporary proxy skipped CA trust\n' >&2;exit 1;fi
printf '%s %s\n' "$mac" "$(($(date +%s)+2))" > "$PA_TEMP_PROXY_FILE"
apply
sleep 3
expect 198.18.0.2:80 PROXY
expect_tls 198.18.0.2:443
# A permanent projection has no kernel timeout and survives a policy rebuild.
printf '%s 0\n' "$mac" > "$PA_TEMP_PROXY_FILE"
apply
expect_tls 198.18.0.2:443 TEMP_TLS
apply --replace
expect 198.18.0.2:80 TEMP_HTTP
# Revoke and rebuild must clear the permanent kernel element as well.
rm -f "$PA_TEMP_PROXY_FILE"
apply
expect_tls 198.18.0.2:443
# A forged temporary record for an unapproved MAC must never grant access.
printf '%s %s\n' '02:00:00:00:00:99' "$future" > "$PA_TEMP_PROXY_FILE"
apply
ip -n "$c" link set client0 address 02:00:00:00:00:99
expect 198.18.0.2:80 PORTAL
blocked 198.18.0.2:443
ip -n "$c" link set client0 address "$mac"
rm -f "$PA_TEMP_PROXY_FILE"
apply
printf '%s\n' 'PASS: temporary HTTP/HTTPS/non-web TCP paths; fixture TLS trust checked; direct listeners blocked; kernel timeout restores routing; unknown MAC cannot gain authorization.'
# IPv6 egress must not bypass the IPv4 certificate proxy.
for ns in "$r" "$c" "$w"; do
    ip netns exec "$ns" sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0
done
ip netns exec "$r" sysctl -qw net.ipv6.conf.all.forwarding=1
ip -n "$r" -6 addr add fd77::1/64 dev br-lan nodad
ip -n "$c" -6 addr add fd77::2/64 dev client0 nodad
ip -n "$r" -6 addr add 2001:db8:77::1/64 dev eth0 nodad
ip -n "$w" -6 addr add 2001:db8:77::2/64 dev wan0 nodad
ip -n "$c" -6 route add default via fd77::1
ip -n "$w" -6 route add fd77::/64 via 2001:db8:77::1
if ip netns exec "$c" ping -6 -c 1 -W 1 2001:db8:77::2 >/dev/null 2>&1; then printf 'FAIL: IPv6 bypass\n' >&2; exit 1; fi
ip netns exec "$r" nft list chain inet privacy_policy prerouting_gate | grep 'IPv6 internet disabled' | grep -Eq 'packets [1-9][0-9]*' || { printf 'FAIL: IPv6 guard did not receive probe\n' >&2; exit 1; }
runcli add "$mac" 'IoT test' iot 1 >/dev/null
expect 198.18.0.2:80 IOT
expect 198.18.1.2:443 IOT
expect 198.18.1.2:53 DNS
if ip netns exec "$c" ping -c 1 -W 1 198.18.0.2 >/dev/null 2>&1; then printf 'FAIL: IoT ICMP bypass\n' >&2; exit 1; fi
# Revoke during an established transparent-proxy TCP session.
ip netns exec "$c" sh -c '(printf "GET / HTTP/1.1\r\nHost: test\r\n\r\n"; sleep 3; printf "GET / HTTP/1.1\r\nHost: test\r\n\r\n"; sleep 1) | timeout 5 nc 198.18.0.2 80' > "$testdir/established" &
probe_pid="$!"
sleep 1
grep -q IOT "$testdir/established" || { printf 'FAIL: established test did not connect\n' >&2; exit 1; }
runcli add "$mac" 'disabled' iot 0 >/dev/null
wait "$probe_pid" || true
[ "$(grep -o IOT "$testdir/established" | wc -l)" -eq 1 ] || { printf 'FAIL: revoked connection remained usable\n' >&2; exit 1; }
expect 198.18.0.2:80 PORTAL
expect 198.18.1.2:80 PORTAL
runcli remove "$mac" >/dev/null
for invalid in invalid 00:00:00:00:00:00 01:00:00:00:00:01 '02:00:00:00:00:01;reboot'; do
    if runcli add "$invalid" >/dev/null 2>&1; then printf 'FAIL: invalid MAC accepted\n' >&2; exit 1; fi
done
if runcli add "$mac" test bypass 1 >/dev/null 2>&1; then printf 'FAIL: invalid group accepted\n' >&2; exit 1; fi
cp "$UCI_CONFIG_DIR/privacy_access" "$testdir/before-error"
ip netns exec "$r" nft delete table inet privacy_policy
if runcli add "$mac" 'Must roll back' >/dev/null 2>&1; then printf 'FAIL: apply error ignored\n' >&2; exit 1; fi
cmp "$UCI_CONFIG_DIR/privacy_access" "$testdir/before-error"
uci -q -c "$UCI_CONFIG_DIR" set 'privacy_access.bad=device'
uci -q -c "$UCI_CONFIG_DIR" set 'privacy_access.bad.mac=invalid'
uci -q -c "$UCI_CONFIG_DIR" commit privacy_access
sed -e "s#/etc/privacy-classify.sh#$PA_CLASSIFIER#g" -e "s#/etc/privacy-policy.nft#$PA_TEMPLATE#g" "$stage/rootfiles/etc/init.d/privacy-policy" > "$testdir/policy.init"
ip netns exec "$r" sh -c '. "$1"; start' _ "$testdir/policy.init"
expect 198.18.0.2:80 PORTAL
expect 198.18.1.2:80 PORTAL
expect 10.77.0.1:8080 ADMIN
printf '%s\n' 'PASS: real packets on both WANs; normal TLS fails without CA and passes with CA; IPv6 blocked; manual IoT route; no hostname/IP grant; static IP; explicit proxy blocked; disable/delete; established connection revocation; invalid input; failed-apply rollback.'
