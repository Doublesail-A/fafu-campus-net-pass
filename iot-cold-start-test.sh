#!/bin/sh
# Real core/cache test in private storage. No production listeners, nft or restart.
set -eu
stage="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
testdir="$(mktemp -d /tmp/privacy-iot-start-test.XXXXXX)"
pid=''
cleanup(){
    [ -z "$pid" ] || { kill "$pid" 2>/dev/null || true;wait "$pid" 2>/dev/null || true; }
    case "$testdir" in /tmp/privacy-iot-start-test.?*) rm -rf "$testdir";;esac
}
trap cleanup EXIT
. "$stage/rootfiles/etc/init.d/iot-proxy"
RUNTIME_DIR="$testdir/cold/runtime"
CONF="$testdir/config.json"
lua - "$CONF" "$RUNTIME_DIR/cache.db" <<'LUA'
local f=assert(io.open(arg[1],'w'))
f:write(require('luci.jsonc').stringify({log={disabled=true},outbounds={{type='direct',tag='direct'}},experimental={cache_file={enabled=true,path=arg[2]}}}));f:close()
LUA
checks=0
setup_nft(){ [ -d "$RUNTIME_DIR" ] && [ "$(stat -c '%a' "$RUNTIME_DIR")" = 700 ];checks=$((checks+1)); }
setup_egress_bypass(){ :; }
setup_exclusions(){ :; }
procd_open_instance(){ :; }
procd_set_param(){ :; }
procd_close_instance(){ "$PROG" run -c "$CONF" > "$testdir/core.log" 2>&1 & pid=$!; }
[ ! -e "$RUNTIME_DIR" ]
start_service
for i in 1 2 3 4 5 6 7 8 9 10;do [ ! -f "$RUNTIME_DIR/cache.db" ] || break;sleep 1;done
kill -0 "$pid";[ -f "$RUNTIME_DIR/cache.db" ];[ "$checks" = 1 ]
[ "$(stat -c '%a' "$RUNTIME_DIR/cache.db")" = 600 ]
kill "$pid";wait "$pid" || true;pid=''
chmod 755 "$RUNTIME_DIR"
chmod 644 "$RUNTIME_DIR/cache.db"
start_service
sleep 1
kill -0 "$pid";[ "$(stat -c '%a' "$RUNTIME_DIR")" = 700 ];[ "$checks" = 2 ]
[ "$(stat -c '%a' "$RUNTIME_DIR/cache.db")" = 600 ]
kill "$pid";wait "$pid" || true;pid=''
RUNTIME_DIR="$testdir/config.json/impossible"
if start_service 2>/dev/null;then echo 'Unexpected successful start with invalid runtime path' >&2;exit 1;fi
[ "$checks" = 2 ]
echo 'PASS: missing runtime created before startup, real core cache initialized 0600, existing permissions hardened, invalid directory fails before firewall/daemon setup.'
