#!/bin/sh
set -e
stage="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
testdir="$(mktemp -d /tmp/privacy-registration-test.XXXXXX)"
trap 'case "$testdir" in /tmp/privacy-registration-test.?*) rm -rf "$testdir" ;; esac' EXIT
export PA_REG_SECRET="$testdir/secret" PA_REG_LAST="$testdir/last" PA_REG_RUNTIME="$testdir/runtime" PA_REG_LOCK="$testdir/lock"
. "$stage/rootfiles/usr/share/privacy-access/registration.sh"
# RFC 6238 SHA-1 vectors, truncated to the configured six decimal digits.
printf '%s\n' 3132333435363738393031323334353637383930 > "$PA_REG_SECRET"
[ "$(pa_reg_code 1)" = 287082 ]
[ "$(pa_reg_code $((1111111109 / 30)))" = 081804 ]
[ "$(pa_reg_code $((1111111111 / 30)))" = 050471 ]
[ "$(pa_reg_code $((1234567890 / 30)))" = 005924 ]
[ "$(pa_reg_code $((2000000000 / 30)))" = 279037 ]
[ "$(pa_reg_code $((20000000000 / 30)))" = 353130 ]
[ "$(cat "$PA_REG_SECRET" | pa_reg_base32)" = GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ ]
pa_reg_verify 287082 59
printf '%s\n' "$PA_REG_ACCEPTED_STEP" > "$PA_REG_LAST"
if pa_reg_verify 287082 59; then printf 'FAIL: OTP replay\n' >&2; exit 1; fi
rm -f "$PA_REG_LAST"
token="$(pa_reg_token 10:00:00:00:00:88 172.31.255.251 "$(($(date +%s)/600))")"
pa_reg_check_token "$token" 10:00:00:00:00:88 172.31.255.251
if pa_reg_check_token "$token" 10:00:00:00:00:99 172.31.255.251; then printf 'FAIL: MAC token binding\n' >&2; exit 1; fi
if pa_reg_check_token "$token" 10:00:00:00:00:88 172.31.255.250; then printf 'FAIL: IP token binding\n' >&2; exit 1; fi
for n in 1 2 3 4 5; do pa_reg_rate_check testmac; pa_reg_rate_fail testmac; done
if pa_reg_rate_check testmac; then printf 'FAIL: brute force limit\n' >&2; exit 1; fi
printf '%s\n' 'PASS: standard TOTP vectors/base32; consumed-code replay prevention; CSRF binding to MAC/IP; five-attempt rate limit.'
