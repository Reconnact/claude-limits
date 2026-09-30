#!/bin/bash
# Tests for ./install and ./statusline, in a temp home
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"

FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/claude" CLAUDE_LIMITS_DIR="$TMP/data"
SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"

check() {   # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"
    FAILED=1
  fi
}
install() { ./install --no-menubar; }

# a fresh account
OUT="$(install)"; CODE=$?
check "exits 0" "0" "$CODE"
check "data folder is 1777" "drwxrwxrwt" "$(stat -f '%Sp' "$CLAUDE_LIMITS_DIR")"
check "status line points at the bundled script" "$REPO/statusline" "$(jq -r .statusLine.command "$SETTINGS")"
check "says where the page is" "1" "$(grep -c 'index.html' <<<"$OUT")"

# again
check "second run leaves it" "1" "$(install | grep -c 'already records')"

# settings with other keys and no status line
echo '{"theme":"dark"}' > "$SETTINGS"
install >/dev/null
check "other settings are kept" "dark" "$(jq -r .theme "$SETTINGS")"
check "backup written" "dark" "$(jq -r .theme "$SETTINGS.bak")"

# an own status line is not touched
printf '#!/bin/sh\necho hi\n' > "$TMP/own.sh"
echo "{\"statusLine\":{\"type\":\"command\",\"command\":\"$TMP/own.sh\"}}" > "$SETTINGS"
OUT="$(install)"
check "own status line stays" "$TMP/own.sh" "$(jq -r .statusLine.command "$SETTINGS")"
check "own status line gets the snippet" "1" "$(grep -c "$REPO/collect" <<<"$OUT")"

# an own status line that already calls collect
printf '#!/bin/sh\n"$HOME/Workspace/claude-limits/collect"\n' > "$TMP/own.sh"
check "own status line with collect is fine" "1" "$(install | grep -c 'already records')"

# the bundled status line records and shows
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 44\n' > "$TMP/bin/security"; chmod +x "$TMP/bin/security"
OUT="$(printf '{"model":{"display_name":"Fable 5.1"},"rate_limits":{"five_hour":{"used_percentage":23.4,"resets_at":1790000000},"seven_day":{"used_percentage":41,"resets_at":1790400000}}}' | PATH="$TMP/bin:$PATH" ./statusline)"
check "status line shows model and limits" "Fable 5.1 · 5h 23% · 7d 41%" "$OUT"
check "status line recorded a snapshot" "1" "$(wc -l < "$CLAUDE_LIMITS_DIR/$(id -un).js" | tr -d ' ')"
OUT="$(printf '{"model":{"display_name":"Fable 5.1"}}' | ./statusline)"
check "no limits, model only" "Fable 5.1" "$OUT"

exit $FAILED
