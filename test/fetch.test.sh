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
cat > "$TMP/bin/security" <<'SH'
#!/bin/sh
printf '{"claudeAiOauth":{"accessToken":"tok"}}'
SH
cat > "$TMP/bin/curl" <<SH
#!/bin/sh
cat > "$TMP/curl-stdin"
printf '%s ' "\$@" > "$TMP/curl-args"
cat "$TMP/answer.json"
SH
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
export CLAUDE_LIMITS_DIR="$TMP/out"
mkdir -p "$TMP/out"; touch "$TMP/out/.$(id -un)-fetched"

cat > "$TMP/answer.json" <<'JSON'
{"five_hour":{"utilization":4.0,"resets_at":"2026-09-30T12:59:59.606131+00:00"},
 "seven_day":{"utilization":69.0,"resets_at":"2026-09-30T19:59:59.606157+00:00"},
 "limits":[
  {"kind":"session","percent":4,"resets_at":"2026-09-30T12:59:59.606131+00:00","scope":null},
  {"kind":"weekly_scoped","percent":76,"resets_at":"2026-09-30T19:59:59.606366+00:00","scope":{"model":{"display_name":"Fable"}}}]}
JSON
./fetch-usage
OUT="$TMP/out/$(id -un).js"
json() { tail -1 "$OUT" | sed 's/^S.push(//; s/);$//'; }
check "writes one line" "1" "$(wc -l < "$OUT" | tr -d ' ')"
check "5 h window" "4 1790773199" "$(json | jq -r '.five_hour | "\(.used_percentage | round) \(.resets_at)"')"
check "7 d window" "69 1790798399" "$(json | jq -r '.seven_day | "\(.used_percentage | round) \(.resets_at)"')"
check "fable window" "76 1790798399" "$(json | jq -r '.fable | "\(.used_percentage) \(.resets_at)"')"
check "token goes in on stdin" 'header = "Authorization: Bearer tok"' "$(cat "$TMP/curl-stdin")"
check "token is not an argument" "" "$(grep -o tok "$TMP/curl-args")"

# an answer without the Fable limit still records the other two
rm "$OUT"
jq 'del(.limits[1])' "$TMP/answer.json" > "$TMP/a" && mv "$TMP/a" "$TMP/answer.json"
./fetch-usage
check "no fable limit, no fable key" "false" "$(json | jq 'has("fable")')"
check "no fable limit, 7 d still written" "69" "$(json | jq -r '.seven_day.used_percentage | round')"

# a changed or failed answer writes nothing
rm "$OUT"
printf '<html>' > "$TMP/answer.json"
./fetch-usage; CODE=$?
check "garbage answer exits 0" "0" "$CODE"
check "garbage answer writes nothing" "no" "$([ -f "$OUT" ] && echo yes || echo no)"

# no token, no call
printf '#!/bin/sh\nexit 44\n' > "$TMP/bin/security"
rm -f "$TMP/curl-args"
./fetch-usage
check "no token, no curl" "no" "$([ -f "$TMP/curl-args" ] && echo yes || echo no)"

exit $FAILED
