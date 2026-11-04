#!/bin/sh
# MACs, not DHCP addresses or hostname guesses, are the only authority.
. "${PA_LIBRARY:-/usr/share/privacy-access/common.sh}"
PA_LOCK="${PA_LOCK:-/tmp/privacy-classify.lock}"
own_lock=1
case "${1:-}" in
    --locked) own_lock=0 ;; # Caller owns the same lock across UCI commit and apply.
    ''|--replace) umask 077; exec 8>>"$PA_LOCK"; flock -x 8 || exit 1 ;;
    *) printf '%s\n' 'Invalid classifier arguments' >&2; exit 1 ;;
esac
batch=''
cleanup() { [ -z "$batch" ] || rm -f "$batch"; [ "$own_lock" = '0' ] || flock -u 8; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
pa_load_access || { printf '%s\n' 'Invalid privacy_access configuration' >&2; exit 1; }
batch="$(mktemp /tmp/privacy-classify.XXXXXX)" || exit 1
if [ "${1:-}" = '--replace' ]; then
    if nft list table inet "$PA_POLICY_TABLE" >/dev/null 2>&1; then
        printf 'delete table inet %s\n' "$PA_POLICY_TABLE" >> "$batch"
    fi
    sed "s/table inet privacy_policy/table inet $PA_POLICY_TABLE/" "$PA_TEMPLATE" >> "$batch"
elif ! nft list set inet "$PA_POLICY_TABLE" allowed_macs >/dev/null 2>&1; then
    printf '%s\n' 'Strict MAC policy is not running; permissions were not applied' >&2
    exit 1
fi
append_set() {
    local table="$1" set_name="$2" values="$3" elements
    printf 'flush set inet %s %s\n' "$table" "$set_name" >> "$batch"
    elements="$(printf '%s\n' "$values" | sort -u | awk 'BEGIN{sep=""} NF{printf "%s%s",sep,$1;sep=", "}')"
    [ -z "$elements" ] || printf 'add element inet %s %s { %s }\n' "$table" "$set_name" "$elements" >> "$batch"
}
append_set "$PA_POLICY_TABLE" allowed_macs "$PA_ALLOWED_MACS"
append_set "$PA_POLICY_TABLE" normal_macs "$PA_NORMAL_MACS"
append_set "$PA_POLICY_TABLE" iot_macs "$PA_IOT_MACS"
if [ "${1:-}" = '--replace' ] || nft list set inet "$PA_POLICY_TABLE" temporary_proxy_macs >/dev/null 2>&1; then
    printf 'flush set inet %s temporary_proxy_macs\n' "$PA_POLICY_TABLE" >> "$batch"
    [ -z "$PA_PROXY_ELEMENTS" ] || printf 'add element inet %s temporary_proxy_macs { %s }\n' "$PA_POLICY_TABLE" "$PA_PROXY_ELEMENTS" >> "$batch"
fi
# Clear obsolete IP-based exemptions instead of repopulating legacy files.
if nft list set inet "$PA_IOT_TABLE" iot_set >/dev/null 2>&1; then
    append_set "$PA_IOT_TABLE" iot_set ''
fi
if nft list set inet "$PA_MITM_TABLE" privacy_mitm_bypass >/dev/null 2>&1; then
    append_set "$PA_MITM_TABLE" privacy_mitm_bypass ''
fi
# Replacement and group updates commit in one nft transaction.
nft -f "$batch" || exit 1
# Keep reported device names separately from the user's existing remarks.
# Write flash only when a hostname actually changes.
PA_HOSTNAMES_CHANGED=0
config_foreach pa_sync_hostnames device
if [ "$PA_HOSTNAMES_CHANGED" = '1' ]; then
    uci -q -c "$PA_CONFIG_DIR" commit privacy_access || logger -t privacy-access 'Unable to persist discovered hostnames'
fi
