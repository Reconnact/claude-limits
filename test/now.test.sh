#!/bin/bash
# Tests for ./now, against data files in a temp dir
cd "$(dirname "$0")/.." || exit 1

FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_LIMITS_DIR="$TMP"
NOW="$(date +%s)"

check() {   # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"
    FAILED=1
  fi
}
# no Keychain in the tests, so --fresh stops before the network
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 44\n' > "$TMP/bin/security"; chmod +x "$TMP/bin/security"
export PATH="$TMP/bin:$PATH"
line() {   # line <file> <ts> <5h pct> <5h reset> <7d pct> <7d reset>
  printf 'S.push({"ts":%s,"source":"x","five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}});\n' "$2" "$3" "$4" "$5" "$6" >> "$TMP/$1.js"
}

check "no data: every field null" '{"five_hour":null,"seven_day":null,"fable":null,"ts":null,"age":null}' "$(./now | jq -c .)"

line hw $((NOW - 600)) 24 $((NOW + 3600)) 69 $((NOW + 90000))
line reconnact $((NOW - 300)) 26 $((NOW + 3600)) 69 $((NOW + 90000))
printf 'S.push({"ts":%s,"source":"hw","fable":{"used_percentage":76,"resets_at":%s}});\n' $((NOW - 1200)) $((NOW + 90000)) >> "$TMP/hw.js"
printf 'S.push({"ts":%s,"source":"reconnact"});\n' $((NOW - 30)) > "$TMP/reconnact-checked.js"
printf 'SOURCES.push("hw");\nSOURCES.push("reconnact");\n' > "$TMP/sources.js"
check "the highest value of the newest window, from any account" "26 $((NOW + 3600))" "$(./now | jq -r '"\(.five_hour.used_percentage) \(.five_hour.resets_at)"')"
check "a window only the usage endpoint brings" "76" "$(./now | jq -r .fable.used_percentage)"
check "ts is the last check, values or not" "$((NOW - 30))" "$(./now | jq -r .ts)"
AGE="$(./now | jq -r .age)"
check "age in seconds" "yes" "$([ "$AGE" -ge 30 ] && [ "$AGE" -lt 40 ] && echo yes || echo no)"

rm "$TMP"/*.js
line hw $((NOW - 7200)) 80 $((NOW - 60)) 69 $((NOW + 90000))
check "a window past its reset is 0 with no reset" "0 null" "$(./now | jq -r '"\(.five_hour.used_percentage) \(.five_hour.resets_at)"')"
check "a window never recorded is null" "null" "$(./now | jq -r .fable)"
check "--fresh without a token still answers" "69" "$(./now --fresh | jq -r .seven_day.used_percentage)"

exit $FAILED
