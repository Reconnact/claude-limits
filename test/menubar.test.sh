#!/bin/bash
# Tests for menubar/claude-limits-bar --print, against data files in a temp dir
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
bar() { ./menubar/claude-limits-bar --print; }
line() {   # line <ts> <pct> <resets_at>
  printf 'S.push({"ts":%s,"source":"x","five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":69,"resets_at":%s}});\n' "$1" "$2" "$3" "$3"
}

check "no files" "–" "$(bar)"

line $((NOW - 60)) 5.6 $((NOW + 3600)) > "$TMP/hw.js"
check "live window, rounded" "6%" "$(bar)"

line $((NOW - 7200)) 40 $((NOW - 60)) > "$TMP/hw.js"
check "expired window" "0%" "$(bar)"

line $((NOW - 600)) 10 $((NOW + 3600)) > "$TMP/hw.js"
line $((NOW - 60)) 12 $((NOW + 3600)) > "$TMP/reconnact.js"
check "newer account wins" "12%" "$(bar)"

printf 'S.push({"ts":%s,"source":"hw","fable":{"used_percentage":76,"resets_at":%s}});\n' "$NOW" $((NOW + 3600)) >> "$TMP/reconnact.js"
check "line without 5 h is skipped" "12%" "$(bar)"

line $((NOW - 60)) 12 $((NOW + 3600)) > "$TMP/reconnact.js"
line $((NOW - 30)) 3 $((NOW + 3600)) > "$TMP/usage-for-claude.js"
check "old app data is ignored" "12%" "$(bar)"

line $((NOW - 60)) 27 $((NOW + 3602)) > "$TMP/reconnact.js"
line $((NOW - 60)) 28 $((NOW + 3600)) >> "$TMP/reconnact.js"
check "same second, the higher value" "28%" "$(bar)"
line $((NOW - 60)) 5 $((NOW + 5 * 3600)) >> "$TMP/reconnact.js"
check "a newer window wins over a higher value" "5%" "$(bar)"

rm "$TMP"/*.js
line $((NOW - 60)) 33 $((NOW + 3600)) > "$TMP/someone.js"
printf 'SOURCES.push("someone");\n' > "$TMP/sources.js"
check "any account name, index ignored" "33%" "$(bar)"

menu() { ./menubar/claude-limits-bar --menu | cut -f1,2 | tr '\t' ' ' | paste -sd '|' -; }

rm "$TMP"/*.js
check "menu without data" "" "$(menu)"

line $((NOW - 60)) 24 $((NOW + 3600)) > "$TMP/hw.js"
printf 'S.push({"ts":%s,"source":"hw","fable":{"used_percentage":76,"resets_at":%s}});\n' "$NOW" $((NOW + 3600)) >> "$TMP/hw.js"
check "menu has every limit" "5 h 24 %|7 d 69 %|Fable 76 %" "$(menu)"

line $((NOW - 3 * 3600)) 40 $((NOW + 3600)) > "$TMP/hw.js"
check "menu shows the age of an old snapshot" "5 h 40 %|7 d 69 %|last snapshot 3 h ago" "$(menu)"

exit $FAILED
