#!/bin/sh
# Passive presence only: Wi-Fi associations and recently learned wired MACs.
# A lease alone is never evidence that a device is connected.
pa_static_host() {
    local section="$1" macs name mac
    config_get macs "$section" mac
    config_get name "$section" name
    [ -n "$name" ] || return 0
    name="$(printf '%s' "$name" | tr '\t\r\n' '   ')"
    for mac in $macs; do printf 'H %s\t%s\n' "$(pa_normalize_mac "$mac")" "$name"; done
}
pa_build_inventory() {
    local dir="$1" iface path port kind
    : > "$dir/events"
    if [ -f "$PA_LEASES" ]; then sed 's/^/L /' "$PA_LEASES" >> "$dir/events"; fi
    if [ -n "${PA_DISCOVERY_FIXTURE:-}" ]; then
        cat "$PA_DISCOVERY_FIXTURE/events" >> "$dir/events"
    else
        ip -4 neigh show dev br-lan 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="lladdr")print "N",tolower($(i+1)),$1,$NF}' >> "$dir/events"
        for iface in $(iw dev 2>/dev/null | awk '$1=="Interface" {print $2}'); do
            [ -e "/sys/class/net/br-lan/brif/$iface" ] || continue
            iw dev "$iface" station dump 2>/dev/null | awk -v iface="$iface" '$1=="Station" {print "S",tolower($2),iface}' >> "$dir/events"
        done
        : > "$dir/ports"
        for path in /sys/class/net/br-lan/brif/*; do
            [ -r "$path/port_no" ] || continue
            iface="${path##*/}"; port="$(cat "$path/port_no")"
            kind='wired'
            [ ! -e "/sys/class/net/$iface/phy80211" ] || kind='wifi'
            printf '%s %s\n' "$((port))" "$kind" >> "$dir/ports"
        done
        brctl showmacs br-lan 2>/dev/null | awk 'NR==FNR {kind[$1]=$2;next} $3=="no" && ($1 in kind) {print "F",tolower($2),kind[$1],$4}' "$dir/ports" - >> "$dir/events"
        (config_load dhcp >/dev/null 2>&1 && config_foreach pa_static_host host) >> "$dir/events"
    fi
    awk -v now="$(date +%s)" '
    function ipv4(s,a,n,i) {n=split(s,a,".");if(n!=4)return 0;for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]>255)return 0;return s!~/^169[.]254[.]/}
    $1=="L" && NF>=5 {
        m=tolower($3); seen[m]=1
        if($5!="*" && $5!="") names[m]=$5
        if(($2==0 || $2>now) && ipv4($4)) lease[m SUBSEP $4]=1
    }
    $1=="H" {m=tolower($2);seen[m]=1;if(!names[m])names[m]=$3}
    $1=="N" && ipv4($3) {m=tolower($2);seen[m]=1;if($4=="REACHABLE"||$4=="DELAY"||$4=="PROBE")recent[m]=$3;else stale[m]=$3}
    $1=="S" {m=tolower($2);seen[m]=1;wifi[m]=1}
    $1=="F" {m=tolower($2);seen[m]=1;if($3=="wired" && $4+0<=120)wired[m]=1}
    END {
        for(m in seen) {
            connected=(wifi[m]||wired[m])?1:0; source=wifi[m]?"wifi":(wired[m]?"wired":"-"); ips=""
            for(k in lease) {split(k,a,SUBSEP);if(a[1]==m)ips=ips (ips?",":"") a[2]}
            if(connected && recent[m] && index("," ips ",","," recent[m] ",")==0)ips=recent[m] (ips?"," ips:"")
            if(connected && !ips && stale[m])ips=stale[m]
            printf "%s\t%s\t%s\t%d\t%s\n",m,(ips?ips:"-"),(names[m]?names[m]:"*"),connected,source
        }
    }' "$dir/events" | sort > "$dir/inventory"
}
