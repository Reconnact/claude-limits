#!/bin/bash
# Tests for ./update, against a local origin, with fake launchctl and make on PATH
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"

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
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/launchctl"
printf '#!/bin/sh\necho "$@" >> "%s/make-calls"\n' "$TMP" > "$TMP/bin/make"
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q -b main "$TMP/origin"
cp "$SRC/update" "$TMP/origin/"; mkdir "$TMP/origin/menubar"; echo a > "$TMP/origin/menubar/x.swift"; echo a > "$TMP/origin/README.md"
git -C "$TMP/origin" add -A && git -C "$TMP/origin" commit -q -m one
git clone -q "$TMP/origin" "$TMP/clone"
commit() { echo "$2" > "$TMP/origin/$1" && git -C "$TMP/origin" commit -q -am "$2"; }

commit README.md b
"$TMP/clone/update"
check "pulls a new commit" "b" "$(cat "$TMP/clone/README.md")"
check "no menu bar change, no rebuild" "no" "$([ -f "$TMP/make-calls" ] && echo yes || echo no)"

commit menubar/x.swift b
"$TMP/clone/update"
check "menu bar change rebuilds it" "-s install-menubar" "$(cat "$TMP/make-calls")"

rm "$TMP/make-calls"
printf '#!/bin/sh\nexit 113\n' > "$TMP/bin/launchctl"
commit menubar/x.swift c
"$TMP/clone/update"
check "menu bar not installed, not built" "no" "$([ -f "$TMP/make-calls" ] && echo yes || echo no)"

echo mine > "$TMP/clone/README.md"
commit README.md d
"$TMP/clone/update"
check "own changes, no pull" "mine" "$(cat "$TMP/clone/README.md")"

git -C "$TMP/clone" checkout -q README.md
echo e > "$TMP/clone/README.md" && git -C "$TMP/clone" commit -q -am e
"$TMP/clone/update" 2>/dev/null
check "diverged, stays as it is" "e" "$(cat "$TMP/clone/README.md")"

exit $FAILED
