#!/bin/sh
PA_REG_SECRET="${PA_REG_SECRET:-/etc/privacy-registration.secret}"
PA_REG_LAST="${PA_REG_LAST:-/etc/privacy-registration.last-step}"
PA_REG_RUNTIME="${PA_REG_RUNTIME:-/tmp/privacy-registration}"
PA_REG_LOCK="${PA_REG_LOCK:-/tmp/privacy-registration.lock}"
pa_reg_init() {
    [ -s "$PA_REG_SECRET" ] && return 0
    local pending="$PA_REG_SECRET.new"
    (umask 077; openssl rand -hex 20 > "$pending") || return 1
    chmod 600 "$pending" && mv "$pending" "$PA_REG_SECRET"
}
pa_reg_key() {
    local key
    key="$(cat "$PA_REG_SECRET" 2>/dev/null)"
    printf '%s\n' "$key" | grep -Eq '^[0-9a-f]{40}$' || return 1
    printf '%s' "$key"
}
pa_reg_base32() {
    awk 'BEGIN {hex="0123456789abcdef"; alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"}
    {buffer=0;bits=0;for(i=1;i<=length($0);i+=2){
        byte=(index(hex,substr($0,i,1))-1)*16+index(hex,substr($0,i+1,1))-1;
        buffer=buffer*256+byte;bits+=8;
        while(bits>=5){bits-=5;p=2^bits;printf "%s",substr(alphabet,int(buffer/p)+1,1);buffer=buffer%p}
    }} END {if(bits)printf "%s",substr(alphabet,buffer*2^(5-bits)+1,1)}'
}
pa_reg_code() {
    local step="$1" key bytes='' i shift value digest offset truncated
    key="$(pa_reg_key)" || return 1
    for i in 7 6 5 4 3 2 1 0; do
        shift="$((i * 8))"; value="$(((step >> shift) & 255))"
        bytes="$bytes$(printf '\\%03o' "$value")"
    done
    digest="$(printf '%b' "$bytes" | openssl dgst -sha1 -mac HMAC -macopt "hexkey:$key" -binary | hexdump -v -e '1/1 "%02x"')"
    [ "${#digest}" -eq 40 ] || return 1
    offset="$((0x$(printf '%s' "$digest" | cut -c 40)))"
    truncated="$(printf '%s' "$digest" | cut -c "$((offset * 2 + 1))-$((offset * 2 + 8))")"
    printf '%06d' "$(((0x$truncated & 2147483647) % 1000000))"
}
pa_reg_verify() {
    local input="$1" now="${2:-$(date +%s)}" step candidate last='-1'
    printf '%s\n' "$input" | grep -Eq '^[0-9]{6}$' || return 1
    [ ! -s "$PA_REG_LAST" ] || read -r last < "$PA_REG_LAST"
    case "$last" in ''|*[!0-9]*) last='-1' ;; esac
    step="$((now / 30))"
    for candidate in "$step" "$((step - 1))" "$((step + 1))"; do
        [ "$candidate" -gt "$last" ] || continue
        if [ "$(pa_reg_code "$candidate")" = "$input" ]; then PA_REG_ACCEPTED_STEP="$candidate"; return 0; fi
    done
    return 1
}
pa_reg_enabled() { [ "$(uci -q -c "$PA_CONFIG_DIR" get privacy_access.main.registration_enabled)" = '1' ]; }
pa_reg_token() {
    local mac="$1" ip="$2" window="$3" key
    key="$(pa_reg_key)" || return 1
    printf 'enroll:%s:%s:%s' "$mac" "$ip" "$window" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$key" | awk '{print $NF}'
}
pa_reg_check_token() {
    local token="$1" mac="$2" ip="$3" window
    printf '%s\n' "$token" | grep -Eq '^[0-9a-f]{64}$' || return 1
    window="$(($(date +%s) / 600))"
    [ "$token" = "$(pa_reg_token "$mac" "$ip" "$window")" ] || [ "$token" = "$(pa_reg_token "$mac" "$ip" "$((window - 1))")" ]
}
pa_reg_rate_check() {
    local id="$1" now bucket count start
    now="$(date +%s)"
    mkdir -p "$PA_REG_RUNTIME"; chmod 700 "$PA_REG_RUNTIME"
    for bucket in "$id:5" global:30; do
        start=0; count=0
        [ ! -f "$PA_REG_RUNTIME/${bucket%:*}" ] || read -r start count < "$PA_REG_RUNTIME/${bucket%:*}"
        if [ "$((now - start))" -lt 300 ] && [ "$count" -ge "${bucket#*:}" ]; then return 1; fi
    done
}
pa_reg_rate_fail() {
    local id="$1" now bucket count start
    now="$(date +%s)"
    for bucket in "$id" global; do
        start=0; count=0
        [ ! -f "$PA_REG_RUNTIME/$bucket" ] || read -r start count < "$PA_REG_RUNTIME/$bucket"
        [ "$((now - start))" -lt 300 ] || { start="$now"; count=0; }
        printf '%s %s\n' "$start" "$((count + 1))" > "$PA_REG_RUNTIME/$bucket"
    done
}
pa_reg_admin() {
    local action="$1" value="${2:-}" now key secret enabled=0
    exec 9>>"$PA_REG_LOCK"
    flock -x 9 || return 1
    PA_REG_WRITE_LOCK="${PA_WRITE_LOCK:-/tmp/privacy-access-write.lock}"
    PA_REG_CLASSIFY_LOCK="${PA_LOCK:-/tmp/privacy-classify.lock}"
    PA_REG_WRITE_LOCKED=0; PA_REG_CLASSIFY_LOCKED=0
    trap '[ "$PA_REG_CLASSIFY_LOCKED" = 0 ] || flock -u 7; [ "$PA_REG_WRITE_LOCKED" = 0 ] || flock -u 8; flock -u 9' EXIT
    pa_reg_init || return 1
    case "$action" in
        registration-status) [ "$#" -eq 1 ] || return 1 ;;
        registration-enable)
            [ "$#" -eq 2 ] || return 1
            case "$value" in 0|1) ;; *) return 1 ;; esac
            exec 8>>"$PA_REG_WRITE_LOCK"
            flock -x 8 || return 1; PA_REG_WRITE_LOCKED=1
            exec 7>>"$PA_REG_CLASSIFY_LOCK"
            flock -x 7 || return 1; PA_REG_CLASSIFY_LOCKED=1
            uci -q -c "$PA_CONFIG_DIR" set "privacy_access.main.registration_enabled=$value" && uci -q -c "$PA_CONFIG_DIR" commit privacy_access || return 1 ;;
        registration-reset)
            [ "$#" -eq 1 ] || return 1
            (umask 077; openssl rand -hex 20 > "$PA_REG_SECRET.new") && mv "$PA_REG_SECRET.new" "$PA_REG_SECRET" || return 1
            rm -f "$PA_REG_LAST" ;;
        *) return 1 ;;
    esac
    now="$(date +%s)"; key="$(pa_reg_key)"; secret="$(printf '%s' "$key" | pa_reg_base32)"
    pa_reg_enabled && enabled=1
    json_init
    json_add_boolean enabled "$enabled"
    json_add_string secret "$secret"
    json_add_string provisioning_uri "otpauth://totp/Kwrt:LAN-registration?secret=$secret&issuer=Kwrt&algorithm=SHA1&digits=6&period=30"
    json_add_string current_code "$(pa_reg_code "$((now / 30))")"
    json_add_int expires_in "$((30 - now % 30))"
    json_add_string enrollment_url 'http://172.31.255.1:8085/'
    json_dump
}
