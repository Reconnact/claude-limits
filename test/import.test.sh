#!/bin/bash
# Tests for ./import-usage-for-claude
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

cat > "$TMP/a.jsonl" <<'JSON'
{"id":"B","timestamp":1789400000.5,"sessionPercentage":47,"sessionResetsAt":1789410000.898,"weeklyAllModelsPercentage":78,"weeklyResetsAt":1789588800.898,"deviceID":"x"}
{"id":"A","timestamp":1789300000.2,"sessionPercentage":0,"sessionResetsAt":null,"weeklyAllModelsPercentage":8,"weeklyResetsAt":1789588800}
JSON
cat > "$TMP/b.jsonl" <<'JSON'
{"id":"B","timestamp":1789400000.5,"sessionPercentage":47,"sessionResetsAt":1789410000.898,"weeklyAllModelsPercentage":78,"weeklyResetsAt":1789588800.898,"deviceID":"x"}
{"id":"C","timestamp":1789500000,"sessionPercentage":12,"sessionResetsAt":1789510000,"weeklyAllModelsPercentage":80,"weeklyResetsAt":1789588800}
JSON

CLAUDE_LIMITS_DIR="$TMP/out" ./import-usage-for-claude "$TMP/a.jsonl" "$TMP/b.jsonl"; CODE=$?
OUT="$TMP/out/usage-for-claude.js"
check "exits 0" "0" "$CODE"
check "one line per record, a record in both files once" "3" "$(wc -l < "$OUT" | tr -d ' ')"

json() { sed -n "$1p" "$OUT" | sed 's/^S.push(//; s/);$//'; }
check "every line is a push call" "3" "$(grep -c '^S\.push({.*});$' "$OUT")"
check "oldest first" "1789300000 1789400000 1789500000" "$(for i in 1 2 3; do json $i | jq -r .ts; done | tr '\n' ' ' | sed 's/ $//')"
check "source names the old app" "usage-for-claude" "$(json 2 | jq -r .source)"
check "5 h window" "47 1789410000" "$(json 2 | jq -r '.five_hour | "\(.used_percentage) \(.resets_at)"')"
check "7 d window" "78 1789588800" "$(json 2 | jq -r '.seven_day | "\(.used_percentage) \(.resets_at)"')"
check "no reset time, no 5 h window" "null" "$(json 1 | jq -r '.five_hour')"
check "folder is 1777" "drwxrwxrwt" "$(stat -f '%Sp' "$TMP/out")"

# a second run replaces the file
CLAUDE_LIMITS_DIR="$TMP/out" ./import-usage-for-claude "$TMP/a.jsonl"
check "second run replaces the file" "2" "$(wc -l < "$OUT" | tr -d ' ')"
check "old app is listed once" 'SOURCES.push("usage-for-claude");' "$(cat "$TMP/out/sources.js")"

exit $FAILED
