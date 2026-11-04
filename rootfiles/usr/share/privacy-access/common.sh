#!/bin/sh
. /lib/functions.sh
PA_CONFIG_DIR="${UCI_CONFIG_DIR:-/etc/config}"
PA_LEASES="${PA_LEASES:-/tmp/dhcp.leases}"
PA_POLICY_TABLE="${PA_POLICY_TABLE:-privacy_policy}"
PA_IOT_TABLE="${PA_IOT_TABLE:-iot_proxy}"
PA_MITM_TABLE="${PA_MITM_TABLE:-fw4}"
PA_CLASSIFIER="${PA_CLASSIFIER:-/etc/privacy-classify.sh}"
PA_TEMPLATE="${PA_TEMPLATE:-/etc/privacy-policy.nft}"
PA_DISCOVERY="${PA_DISCOVERY:-/usr/share/privacy-access/discovery.sh}"
PA_REG_LIBRARY="${PA_REG_LIBRARY:-/usr/share/privacy-access/registration.sh}"
PA_TEMP_PROXY_FILE="${PA_TEMP_PROXY_FILE:-/etc/privacy-proxy/devices}"
pa_normalize_mac() {
    printf '%s' "$1" | tr 'A-F-' 'a-f:' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}
pa_valid_mac() {
    printf '%s\n' "$1" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || return 1
    [ "$1" != '00:00:00:00:00:00' ] || return 1
    [ "$((0x${1%%:*} & 1))" -eq 0 ]
}
pa_ipv4_list() {
    awk 'function valid(s,a,n,i) {n=split(s,a,".");if(n!=4)return 0;
        for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]>255)return 0;return 1}
        NF && valid($1) {print $1}' | sort -u
}
pa_active_leases() {
    [ -f "$PA_LEASES" ] || return 0
    awk -v now="$(date +%s)" 'NF>=4 && $1~/^[0-9]+$/ && ($1==0 || $1>now) {
        print $1,tolower($2),$3,$4}' "$PA_LEASES"
}
pa_mac_ips() {
    local macs="$1"
    pa_active_leases | awk -v macs="$macs" 'BEGIN {
        n=split(macs,m,/\n/);for(i=1;i<=n;i++)trusted[m[i]]=1}
        tolower($2) in trusted {print $3}' | pa_ipv4_list
}
pa_collect_mac() {
    local section="$1" mac enabled group
    config_get mac "$section" mac
    config_get enabled "$section" enabled '1'
    config_get group "$section" group 'normal'
    mac="$(pa_normalize_mac "$mac")"
    pa_valid_mac "$mac" || { PA_CONFIG_INVALID=1; return; }
    case "$enabled:$group" in 0:normal|1:normal|0:iot|1:iot) ;; *) PA_CONFIG_INVALID=1; return ;; esac
    PA_CONFIGURED_MACS="${PA_CONFIGURED_MACS}${PA_CONFIGURED_MACS:+
}$mac"
    [ "$enabled" = '1' ] || return 0
    if pa_contains "$PA_ALLOWED_MACS" "$mac"; then PA_CONFIG_INVALID=1; return; fi
    PA_ALLOWED_MACS="${PA_ALLOWED_MACS}${PA_ALLOWED_MACS:+
}$mac"
    if [ "$group" = 'iot' ]; then
        PA_IOT_MACS="${PA_IOT_MACS}${PA_IOT_MACS:+
}$mac"
    else
        PA_NORMAL_MACS="${PA_NORMAL_MACS}${PA_NORMAL_MACS:+
}$mac"
    fi
}
pa_load_access() {
    PA_ALLOWED_MACS=''; PA_IOT_MACS=''; PA_NORMAL_MACS=''; PA_CONFIGURED_MACS=''; PA_CONFIG_INVALID=0
    [ -f "$PA_CONFIG_DIR/privacy_access" ] || return 1
    config_load privacy_access || return 1
    config_foreach pa_collect_mac device
    [ "$PA_CONFIG_INVALID" = '0' ] || return 1
    pa_load_temporary_proxy
}
pa_load_temporary_proxy() {
    local mac expires extra now remaining
    PA_PROXY_MACS=''; PA_PROXY_ELEMENTS=''
    [ -f "$PA_TEMP_PROXY_FILE" ] || return 0
    now="$(date +%s)"
    while read -r mac expires extra; do
        [ -z "$extra" ] || continue
        pa_valid_mac "$mac" || continue
        pa_contains "$PA_NORMAL_MACS" "$mac" || continue
        case "$expires" in ''|*[!0-9]*) continue ;; esac
        [ "${#expires}" -le 11 ] || continue
        remaining="$((expires - now))"
        if [ "$expires" != '0' ]; then
            [ "$remaining" -gt 0 ] && [ "$remaining" -le 86400 ] || continue
        fi
        pa_contains "$PA_PROXY_MACS" "$mac" && continue
        PA_PROXY_MACS="${PA_PROXY_MACS}${PA_PROXY_MACS:+
}$mac"
        if [ "$expires" = '0' ]; then
            PA_PROXY_ELEMENTS="${PA_PROXY_ELEMENTS}${PA_PROXY_ELEMENTS:+, }$mac"
        else
            PA_PROXY_ELEMENTS="${PA_PROXY_ELEMENTS}${PA_PROXY_ELEMENTS:+, }$mac timeout ${remaining}s"
        fi
    done < "$PA_TEMP_PROXY_FILE"
    return 0
}
pa_mac_hostname() {
    [ -f "$PA_LEASES" ] || return 0
    awk -v mac="$1" 'tolower($2)==mac && $4!="*" && $4!="" {name=$4} END {print name}' "$PA_LEASES"
}
pa_sync_hostnames() {
    local section="$1" mac current hostname
    config_get mac "$section" mac
    config_get current "$section" hostname ''
    mac="$(pa_normalize_mac "$mac")"
    hostname="$(pa_mac_hostname "$mac")"
    [ -n "$hostname" ] && [ "$hostname" != "$current" ] || return 0
    if uci -q -c "$PA_CONFIG_DIR" set "privacy_access.$section.hostname=$hostname"; then
        PA_HOSTNAMES_CHANGED=1
    fi
}
pa_contains() {
    [ -n "$2" ] && printf '%s\n' "$1" | grep -Fxq "$2"
}
pa_nft_macs() {
    nft list set inet "$1" "$2" 2>/dev/null |
        sed -n '/elements =/,/}/p' | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | sort -u
}
