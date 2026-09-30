#!/bin/bash
# Tests for ./collect — run with `make test` or `bash test/collect.test.sh`.
cd "$(dirname "$0")/.." || exit 1

FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check() {   # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"
    FAILED=1
  fi
}

# no Keychain in the tests, so the background fetch-usage stops before the network
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 44\n' > "$TMP/bin/security"; chmod +x "$TMP/bin/security"
# nor a git, so the background update leaves this clone alone
cp "$TMP/bin/security" "$TMP/bin/git"
export PATH="$TMP/bin:$PATH"
# and the background tally finds no transcripts
export CLAUDE_CONFIG_DIR="$TMP/claude"

input() {   # input <5h pct> <5h reset> <7d pct> <7d reset>
  printf '{"model":{"display_name":"x"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' "$1" "$2" "$3" "$4"
}

run() {     # run <dir> — stdin is passed on to collect
  CLAUDE_LIMITS_DIR="$1" ./collect
}

lines() {   # lines <dir>
  if [ -f "$1/$(id -un).js" ]; then wc -l < "$1/$(id -un).js" | tr -d ' '; else echo 0; fi
}

# a snapshot with both windows is appended and printed
D="$TMP/first"
OUT="$(input 23.4 1790000000 41.2 1790400000 | run "$D")"
check "prints both percentages, rounded" "$(printf '23\t41')" "$OUT"
check "appends one line" "1" "$(lines "$D")"
LINE="$(tail -1 "$D/$(id -un).js")"
check "line is a push call" "S.push(" "${LINE:0:7}"
check "line ends the call" ");" "${LINE: -2}"
JSON="${LINE#S.push(}"; JSON="${JSON%);}"
check "line carries the source" "$(id -un)" "$(jq -r .source <<<"$JSON")"
check "line carries the 5 h window as it came" "23.4 1790000000" "$(jq -r '.five_hour | "\(.used_percentage) \(.resets_at)"' <<<"$JSON")"
check "line carries the 7 d window as it came" "41.2 1790400000" "$(jq -r '.seven_day | "\(.used_percentage) \(.resets_at)"' <<<"$JSON")"
check "line carries a timestamp" "number" "$(jq -r '.ts | type' <<<"$JSON")"

# the folder is made for both accounts
check "folder is 1777" "drwxrwxrwt" "$(stat -f '%Sp' "$D")"

# the same snapshot again writes nothing
input 23.4 1790000000 41.2 1790400000 | run "$D" >/dev/null
check "same snapshot twice stays one line" "1" "$(lines "$D")"

# every check, news or not, overwrites the checked file with a snapshot without values
CHECKED="$D/$(id -un)-checked.js"
printf 'S.push({"ts":1,"source":"old"});\n' > "$CHECKED"
input 23.4 1790000000 41.2 1790400000 | run "$D" >/dev/null
check "a check that is no news still writes nothing" "1" "$(lines "$D")"
check "check is one line" "1" "$(wc -l < "$CHECKED" | tr -d ' ')"
check "check carries the source and no values" "$(id -un) null" "$(sed 's/^S.push(//; s/);$//' "$CHECKED" | jq -r '"\(.source) \(.five_hour)"')"
check "check carries a timestamp" "number" "$(sed 's/^S.push(//; s/);$//' "$CHECKED" | jq -r '.ts | type')"

# a lower percentage in the same window comes from an idle session
OUT="$(input 20 1790000000 40 1790400000 | run "$D")"
check "lower percentage writes nothing" "1" "$(lines "$D")"
check "lower percentage is still printed" "$(printf '20\t40')" "$OUT"

# a higher percentage in the same window is news
input 25 1790000000 41.2 1790400000 | run "$D" >/dev/null
check "higher percentage appends" "2" "$(lines "$D")"

# a reset time that moved by seconds is the same window
input 25 1790000030 41.2 1790400000 | run "$D" >/dev/null
check "reset time off by 30 s is the same window" "2" "$(lines "$D")"

# a later window starts low
input 2 1790018000 41.2 1790400000 | run "$D" >/dev/null
check "new window appends" "3" "$(lines "$D")"

# an older window after a newer one comes from an idle session
input 99 1790000000 41.2 1790400000 | run "$D" >/dev/null
check "older window writes nothing" "3" "$(lines "$D")"

# no limits in the input
D="$TMP/none"
OUT="$(printf '{"model":{"display_name":"x"}}' | run "$D")"; CODE=$?
check "no limits prints nothing" "" "$OUT"
check "no limits exits 0" "0" "$CODE"
check "no limits writes nothing" "0" "$(lines "$D")"

# one window only
D="$TMP/one"
OUT="$(printf '{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1790000000}}}' | run "$D")"
check "missing window prints a dash" "$(printf '12\t-')" "$OUT"
check "missing window still appends" "1" "$(lines "$D")"

# a broken last line does not stop the next snapshot
D="$TMP/broken"
mkdir -p "$D"; printf 'S.push({"ts":17\n' > "$D/$(id -un).js"
input 23.4 1790000000 41.2 1790400000 | run "$D" >/dev/null
check "broken last line, next snapshot appends" "2" "$(lines "$D")"

check "no limits, no check" "no" "$([ -f "$TMP/none/$(id -un)-checked.js" ] && echo yes || echo no)"

# input that is no JSON
D="$TMP/garbage"
OUT="$(printf 'not json' | run "$D")"; CODE=$?
check "garbage prints nothing" "" "$OUT"
check "garbage exits 0" "0" "$CODE"

# the Fable window only comes from fetch-usage
fable() {   # fable <pct> <reset>
  printf '{"rate_limits":{"five_hour":{"used_percentage":4,"resets_at":1790000000},"seven_day":{"used_percentage":69,"resets_at":1790400000},"fable":{"used_percentage":%s,"resets_at":%s}}}' "$1" "$2"
}
D="$TMP/fable"
fable 76 1790400000 | run "$D" >/dev/null
check "fable window appends" "1" "$(lines "$D")"
check "line carries the fable window" "76 1790400000" "$(tail -1 "$D/$(id -un).js" | sed 's/^S.push(//; s/);$//' | jq -r '.fable | "\(.used_percentage) \(.resets_at)"')"
input 5 1790000000 69 1790400000 | run "$D" >/dev/null
check "status line snapshot has no fable key" "false" "$(tail -1 "$D/$(id -un).js" | sed 's/^S.push(//; s/);$//' | jq 'has("fable")')"
fable 76 1790400000 | run "$D" >/dev/null
check "same fable after a status line snapshot writes nothing" "2" "$(lines "$D")"
fable 77 1790400000 | run "$D" >/dev/null
check "higher fable appends" "3" "$(lines "$D")"

# the fetch starts at most every 5 min
D="$TMP/stamp"
input 1 1790000000 2 1790400000 | run "$D" >/dev/null
check "first snapshot stamps the fetch" "yes" "$([ -f "$D/.$(id -un)-fetched" ] && echo yes)"
touch -t 202001010000 "$D/.$(id -un)-fetched"
input 1 1790000000 2 1790400000 | run "$D" >/dev/null
check "a stamp older than 5 min is renewed" "yes" "$([ -n "$(find "$D/.$(id -un)-fetched" -mmin -5)" ] && echo yes)"

# every account adds itself to the index once
D="$TMP/sources"
input 1 1790000000 2 1790400000 | run "$D" >/dev/null
input 3 1790000000 2 1790400000 | run "$D" >/dev/null
check "account is listed once" "SOURCES.push(\"$(id -un)\");" "$(cat "$D/sources.js")"
check "index is writable for the next account" "-rw-rw-rw-" "$(stat -f '%Sp' "$D/sources.js")"
D="$TMP/nolimits"
printf '{"model":{"display_name":"x"}}' | run "$D" >/dev/null
check "no data file, no index" "no" "$([ -f "$D/sources.js" ] && echo yes || echo no)"

exit $FAILED
