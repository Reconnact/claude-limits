#!/bin/bash
# Tests for ./fetch-usage, with fake security and curl on PATH
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

mkdir -p "$TMP/bin"
# as in #20: the entry of the macOS account holds the token, the one found by the service alone only MCP servers' state
cat > "$TMP/bin/security" <<'SH'
#!/bin/sh
case " $* " in
  *" -a $(id -un) "*) printf '{"claudeAiOauth":{"accessToken":"tok"}}' ;;
  *) printf '{"mcpOAuth":{}}' ;;
esac
SH
cat > "$TMP/bin/curl" <<SH
#!/bin/sh
cat > "$TMP/curl-stdin"
printf '%s ' "\$@" > "$TMP/curl-args"
cat "$TMP/answer.json"
SH
printf '#!/bin/sh\necho "9.9.9 (Claude Code)"\n' > "$TMP/bin/claude"
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
export CLAUDE_LIMITS_DIR="$TMP/out"
mkdir -p "$TMP/out"; touch "$TMP/out/.$(id -un)-fetched"

cat > "$TMP/answer.json" <<'JSON'
{"five_hour":{"utilization":4.0,"resets_at":"2026-09-30T12:59:59.606131+00:00"},
 "seven_day":{"utilization":69.0,"resets_at":"2026-09-30T19:59:59.606157+00:00"},
 "limits":[
  {"kind":"session","percent":4,"resets_at":"2026-09-30T12:59:59.606131+00:00","scope":null},
  {"kind":"weekly_scoped","percent":76,"resets_at":"2026-09-30T19:59:59.606366+00:00","scope":{"model":{"display_name":"Fable"}}}],
 "cedar_ember":{"eligible":true,"grants":[
  {"id":"a","type":"session","clears":["five_hour"],"resets_left":1,"ends_at":"2026-10-07T20:00:00+00:00"},
  {"id":"b","type":"session","clears":["five_hour"],"resets_left":1,"ends_at":"2026-10-05T20:00:00.123+00:00"},
  {"id":"c","clears":["seven_day"],"resets_left":2,"ends_at":null},
  {"id":"d","gives_back_weekly":true,"clears":[],"resets_left":1},
  {"id":"e","type":"full","clears":["five_hour","seven_day"],"resets_left":1,"paused":true},
  {"id":"f","type":"weekly","clears":["seven_day"],"resets_left":0}]}}
JSON
./fetch-usage
OUT="$TMP/out/$(id -un).js"
json() { tail -1 "$OUT" | sed 's/^S.push(//; s/);$//'; }
check "writes one line" "1" "$(wc -l < "$OUT" | tr -d ' ')"
check "5 h window" "4 1790773199" "$(json | jq -r '.five_hour | "\(.used_percentage | round) \(.resets_at)"')"
check "7 d window" "69 1790798399" "$(json | jq -r '.seven_day | "\(.used_percentage | round) \(.resets_at)"')"
check "fable window" "76 1790798399" "$(json | jq -r '.fable | "\(.used_percentage) \(.resets_at)"')"
check "marked fresh" "true" "$(json | jq .fresh)"
check "token goes in on stdin" 'header = "Authorization: Bearer tok"' "$(cat "$TMP/curl-stdin")"
check "token is not an argument" "" "$(grep -o tok "$TMP/curl-args")"
check "asks for the resets as Claude Code of the installed version" "1 1" "$(grep -c 'cedar_ember=1' "$TMP/curl-args") $(grep -c 'claude-cli/9.9.9 (external, cli)' "$TMP/curl-args")"
RESETS="$TMP/out/$(id -un)-resets.js"
resets() { sed 's/^S.push(//; s/);$//' "$RESETS"; }
check "resets per kind, by type, else by what they clear; a kind's first use-by date; none paused or used up" \
  '[{"kind":"fable","left":1,"ends_at":null},{"kind":"session","left":2,"ends_at":1791230400},{"kind":"weekly","left":2,"ends_at":null}]' "$(resets | jq -c .resets)"
check "resets line has the time and the account" "$(id -un)" "$(resets | jq -r 'select(.ts > 0) | .source')"

# an answer without the Fable limit still records the other two
rm "$OUT"
jq 'del(.limits[1])' "$TMP/answer.json" > "$TMP/a" && mv "$TMP/a" "$TMP/answer.json"
./fetch-usage
check "no fable limit, no fable key" "false" "$(json | jq 'has("fable")')"
check "no fable limit, 7 d still written" "69" "$(json | jq -r '.seven_day.used_percentage | round')"

# an answer without the resets block holds none, so an old line goes
jq 'del(.cedar_ember)' "$TMP/answer.json" > "$TMP/a" && mv "$TMP/a" "$TMP/answer.json"
./fetch-usage
check "no resets block, none held" "[]" "$(resets | jq -c .resets)"

# a changed or failed answer writes nothing
rm "$OUT" "$RESETS"
printf '<html>' > "$TMP/answer.json"
./fetch-usage; CODE=$?
check "garbage answer exits 0" "0" "$CODE"
check "garbage answer writes nothing" "no no" "$([ -f "$OUT" ] && echo yes || echo no) $([ -f "$RESETS" ] && echo yes || echo no)"

# without Claude Code on PATH the call goes out as curl, and the endpoint lists no resets
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/claude"
./fetch-usage
check "no claude, no user agent" "0" "$(grep -c 'claude-cli' "$TMP/curl-args")"

# no entry for the macOS account, so the one found by the service alone
cat > "$TMP/bin/security" <<'SH'
#!/bin/sh
case " $* " in
  *" -a "*) exit 44 ;;
  *) printf '{"claudeAiOauth":{"accessToken":"svc"}}' ;;
esac
SH
./fetch-usage
check "no entry for the account, token of the service alone" 'header = "Authorization: Bearer svc"' "$(cat "$TMP/curl-stdin")"

# no token, no call
printf '#!/bin/sh\nexit 44\n' > "$TMP/bin/security"
rm -f "$TMP/curl-args"
./fetch-usage
check "no token, no curl" "no" "$([ -f "$TMP/curl-args" ] && echo yes || echo no)"

exit $FAILED
