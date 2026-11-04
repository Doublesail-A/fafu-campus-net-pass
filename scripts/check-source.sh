#!/bin/sh
set -eu
base="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
find "$base/rootfiles" "$base/scripts" -type f | while IFS= read -r file;do
 case "$file" in
  *.lua)CHECK_LUA="$file" lua -e 'assert(loadfile(os.getenv("CHECK_LUA")))';;
  *.json)jsonfilter -i "$file" -e '@' >/dev/null;;
  *)if head -1 "$file" | grep -q '^#!/bin/sh';then sh -n "$file";fi;;
 esac
done
sh -n "$base/install.sh"
sh "$base/test.sh"
sh "$base/status-test.sh"
sh "$base/iot-cold-start-test.sh"
sh "$base/registration-test.sh"
lua "$base/proxy-subscription-test.lua" "$base"
lua "$base/proxy-policy-test.lua" "$base"
sing-box check -c /tmp/privacy-proxy-policy-test.json
sing-box check -c "$base/rootfiles/etc/sing-box/privacy-doh.json"
echo 'Source checks passed. No production installation was performed.'
