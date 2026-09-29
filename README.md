# claude-limits

The 5 h and 7 d Claude limits, recorded by the Claude Code status line and shown on a page that is opened from disk. Nothing runs in the background.

## How it works

- Claude Code passes `rate_limits` to the status line script on stdin
- `collect` appends them to `/Users/Shared/claude-limits/<user>.js` when they are news: a later window, or the same window with a higher percentage
- `index.html` loads every account's file as a script and draws the two numbers and the last 7 days

Each macOS account writes its own file. The limits belong to the Claude account, so two macOS accounts on one Claude login report the same number.

## Setup, per macOS account

Clone to `~/Workspace/claude-limits`, then call `collect` from `~/.claude/statusline.sh`:

```bash
INPUT="$(cat)"
IFS=$'\t' read -r H5 D7 < <("$HOME/Workspace/claude-limits/collect" <<<"$INPUT" 2>/dev/null)
```

`H5` and `D7` hold the rounded percentages, `-` for a window that is not in the input.

Account names other than `hw` and `reconnact` go into `SOURCES` in `index.html`.

## Open

```sh
open ~/Workspace/claude-limits/index.html
```

`?dir=<url>` reads the data from another folder.

## Test

```sh
make test
```

Needs `jq` and `node`.
