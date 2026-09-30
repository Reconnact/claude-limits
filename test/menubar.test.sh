#!/bin/bash
# Tests for menubar/claude-limits-bar --print, against data files in a temp dir
cd "$(dirname "$0")/.." || exit 1

FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_LIMITS_DIR="$TMP"
export CLAUDE_LIMITS_SETTINGS="$TMP/settings.json"
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

printf 'S.push({"ts":%s,"source":"hw"});\n' $((NOW - 60)) > "$TMP/hw-checked.js"
check "a recent check hides the age, keeps the values" "5 h 40 %|7 d 69 %" "$(menu)"
rm "$TMP/hw-checked.js"

settings() { printf '%s' "$1" > "$CLAUDE_LIMITS_SETTINGS"; }
title() { ./menubar/claude-limits-bar --title; }
reset_text() { ./menubar/claude-limits-bar --menu | head -1 | cut -f3; }

line $((NOW - 60)) 24 $((NOW + 3600)) > "$TMP/hw.js"
printf 'S.push({"ts":%s,"source":"hw","fable":{"used_percentage":76,"resets_at":%s}});\n' "$NOW" $((NOW + 3600)) >> "$TMP/hw.js"
settings '{"menuBarLimit":"seven_day"}'
check "settings: menu bar shows the 7 d limit" "69%" "$(bar)"
settings '{"menuBarLimit":"highest"}'
check "settings: menu bar shows the highest limit" "76%" "$(bar)"
settings '{'
check "settings: broken file means defaults" "24%" "$(bar)"
settings '{"menuBarLimit":"weekly","resetFormat":"countdown"}'
check "settings: a bad value keeps the other keys" "24%" "$(bar)"
check "settings: countdown in the panel, as on the page" "resets in 1 h" "$(reset_text)"
settings '{}'
check "settings: no menu bar text by default" "" "$(title)"
settings '{"menuBarText":"percent"}'
check "settings: percent in the menu bar" "24%" "$(title)"
settings '{"menuBarText":"both","resetFormat":"countdown"}'
check "settings: percent and countdown in the menu bar" "24% · in 1 h" "$(title)"
settings '{"panelLimits":["fable","five_hour"]}'
check "settings: panel rows in their order" "Fable 76 %|5 h 24 %" "$(menu)"
settings '{"panelLimits":["fable","nope"]}'
check "settings: unknown panel row dropped" "Fable 76 %" "$(menu)"

printf 'S.push({"ts":%s,"source":"hw","five_hour":{"used_percentage":24,"resets_at":%s}});\n' $((NOW - 60)) $((NOW + 3 * 86400 + 4 * 3600 + 30)) > "$TMP/hw.js"
settings '{"resetFormat":"countdown"}'
check "settings: countdown in days" "resets in 3 d 4 h" "$(reset_text)"
printf 'S.push({"ts":%s,"source":"hw","five_hour":{"used_percentage":24,"resets_at":%s}});\n' $((NOW - 60)) $((NOW + 42 * 60)) > "$TMP/hw.js"
check "settings: countdown under an hour" "resets in 42 min" "$(reset_text)"

exit $FAILED
