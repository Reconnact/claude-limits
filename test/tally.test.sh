#!/bin/bash
# Tests for ./tally, with transcripts in a temporary Claude config folder
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

export CLAUDE_CONFIG_DIR="$TMP/claude"
export CLAUDE_LIMITS_DIR="$TMP/out"
mkdir -p "$TMP/out" "$TMP/claude/projects/p/s1/subagents"
OUT="$TMP/out/$(id -un)-tokens.js"

msg() {     # msg <id> <cwd> <timestamp> <model> <output tokens>
  printf '{"type":"assistant","cwd":"%s","timestamp":"%s","message":{"id":"%s","model":"%s","usage":{"input_tokens":1,"cache_creation_input_tokens":30,"cache_read_input_tokens":100,"output_tokens":%s,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}\n' "$2" "$3" "$1" "$4" "$5"
}
rows() { sed 's/^T.push(//; s/);$//' "$OUT" | jq -c "$1"; }

{
  printf '{"type":"user","cwd":"%s/Workspace/a","timestamp":"2026-09-30T10:00:00.000Z"}\n' "$HOME"
  msg m1 "$HOME/Workspace/a" 2026-09-30T10:00:01.000Z claude-opus-5-5 5
  msg m1 "$HOME/Workspace/a" 2026-09-30T10:00:02.000Z claude-opus-5-5 50
  msg m2 "$HOME/Workspace/a/sub" 2026-09-30T10:59:59.000Z claude-opus-5-5 7
  msg m3 "$HOME/Workspace/a/sub" 2026-09-30T11:00:00.000Z claude-opus-5-5 3
  msg m4 "$HOME/Workspace/a" 2026-09-30T11:10:00.000Z '<synthetic>' 0
} > "$TMP/claude/projects/p/s1.jsonl"
msg m5 "$HOME/Workspace/a/sub" 2026-09-30T11:20:00.000Z claude-haiku-4-5-20251001 2 > "$TMP/claude/projects/p/s1/subagents/agent-x.jsonl"
msg m6 /tmp/elsewhere 2026-09-30T10:30:00.000Z claude-fable-5-1 9 > "$TMP/claude/projects/p/s2.jsonl"

./tally
check "one row per hour, project and model" "4" "$(wc -l < "$OUT" | tr -d ' ')"
check "home is ~, the project is where the session started" '"~/Workspace/a"' "$(rows 'select(.model == "claude-opus-5-5" and .hour == 1790762400) | .project')"
check "a repeated message counts once, with its largest usage" "57" "$(rows 'select(.model == "claude-opus-5-5" and .hour == 1790762400) | .output')"
check "the hour starts on the hour" "3" "$(rows 'select(.model == "claude-opus-5-5" and .hour == 1790766000) | .output')"
check "cache writes split by duration" "20 40 200" "$(rows 'select(.model == "claude-opus-5-5" and .hour == 1790762400) | "\(.cache_write_5m) \(.cache_write_1h) \(.cache_read)"' | tr -d '"')"
check "a subagent counts to its session's project" '"~/Workspace/a"' "$(rows 'select(.model | startswith("claude-haiku")) | .project')"
check "outside home stays as is" '"/tmp/elsewhere"' "$(rows 'select(.model == "claude-fable-5-1") | .project')"
check "synthetic messages are left out" "0" "$(rows 'select(.model == "<synthetic>")' | wc -l | tr -d ' ')"

# a fast request gets its own row, a standard one none
sed 's/"output_tokens":9,/"output_tokens":9,"speed":"fast",/' "$TMP/claude/projects/p/s2.jsonl" > "$TMP/fast" && cat "$TMP/fast" > "$TMP/claude/projects/p/s2.jsonl"
msg m8 /tmp/elsewhere 2026-09-30T10:40:00.000Z claude-fable-5-1 4 >> "$TMP/claude/projects/p/s2.jsonl"
rm "$OUT"; ./tally
check "fast and standard apart" '9 fast|4 -' "$(rows 'select(.model == "claude-fable-5-1") | "\(.output) \(.speed // "-")"' | tr -d '"' | sort -r | paste -sd '|' -)"

# a deleted transcript keeps its rows, a longer one grows them
rm "$TMP/claude/projects/p/s2.jsonl"
msg m7 "$HOME/Workspace/a" 2026-09-30T11:30:00.000Z claude-opus-5-5 10 >> "$TMP/claude/projects/p/s1.jsonl"
./tally
check "deleted transcript, rows stay" "13" "$(rows 'select(.model == "claude-fable-5-1") | .output' | paste -sd+ - | bc)"
check "new message adds to its hour" "13" "$(rows 'select(.model == "claude-opus-5-5" and .hour == 1790766000) | .output')"

# no transcripts at all writes nothing
rm -rf "$TMP/claude/projects" "$OUT"
./tally
check "no transcripts, no file" "no" "$([ -f "$OUT" ] && echo yes || echo no)"

exit $FAILED
