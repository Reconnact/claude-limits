# claude-limits

Your Claude plan limits on a page and in the menu bar: the 5-hour window, the weekly limit and the weekly Fable limit, with their history. Claude Code's status line records them, so nothing polls between turns. macOS only.

## Setup

Needs macOS, Claude Code signed in with a Claude subscription, and `jq` (`brew install jq`). The menu bar item also needs `swiftc` (`xcode-select --install`).

```sh
git clone https://github.com/Reconnact/claude-limits.git ~/claude-limits
~/claude-limits/install
```

`install` makes the shared data folder, sets Claude Code's status line and starts the menu bar item at login. Run it again at any time; `./install --no-menubar` leaves out the menu bar.

The next Claude Code turn records the limits. Then:

```sh
open ~/claude-limits/index.html
```

### You already have a status line

`install` leaves your status line alone and prints two lines to add to it. They pass the status line's input to `collect`:

```bash
INPUT="$(cat)"
IFS=$'\t' read -r H5 D7 < <("$HOME/claude-limits/collect" <<<"$INPUT" 2>/dev/null)
```

`H5` and `D7` then hold the rounded percentages, `-` when a window is missing, for your own status line text.

### Several macOS accounts

Run `install` once in each account. Every account writes its own file into `/Users/Shared/claude-limits`, and the page and menu bar read all of them. Accounts on the same Claude login report the same limits, so the page shows one line per limit.

## The page

- a tile per limit with the time to its reset
- the buttons switch the chart between 5 hours, 1 day, 7 days, 30 days and everything (`?days=5h`, `1`, `7`, `30`, `all`)
- a gap between snapshots is idle time: the value holds until its window resets, then 0
- the chart frames each 5 h window up to the 7-day range and each weekly window beyond it, as high as its peak, with its usage filled in; beyond 7 days the 5 h line is left out
- a page older than 30 minutes greys out and shows its age
- a table under the chart lists the tokens and their API price per project for the chosen range, both accounts added up
- `?dir=<url>` reads the data from another folder
- `?reset=time`, `countdown` or `both` shows the reset as in the menu bar's settings; `Open page` passes it, opened from disk the page counts down

Reload for fresh numbers.

## The menu bar

Shows the 5-hour limit as a pie, from the newest snapshot of any account. A click opens a panel under it with each limit, its bar and its reset time, `Open page` (⌘O), which shows the page in a window of its own, fresh on each open, and a gear (⌘,) for the settings; ⌘W or ⌘Q closes either window. `Quit` ends the item; Spotlight starts it again as `claude-limits`, from `~/Applications/claude-limits.app`. It starts at login and re-reads the files every minute. `make uninstall-menubar` removes it.

### Settings

The gear in the panel opens a window for them; they live in `~/.config/claude-limits/settings.json`, one file per macOS account. The window and the file are the same thing: a change in the window saves the file, and an edit to the file, by hand or by Claude, shows in the menu bar and in an open window within a second.

```json
{
  "menuBarLimit": "five_hour",
  "menuBarIcon": "pie",
  "menuBarText": "none",
  "resetFormat": "time",
  "panelLimits": ["five_hour", "seven_day", "fable"],
  "warnAt": 80,
  "refreshSeconds": 60
}
```

| key | values | default | what it does |
|---|---|---|---|
| `menuBarLimit` | `five_hour`, `seven_day`, `fable`, `highest` | `five_hour` | the limit in the menu bar; `highest` is the one closest to full |
| `menuBarIcon` | `pie`, `bar`, `none` | `pie` | the icon |
| `menuBarText` | `none`, `percent`, `reset`, `both` | `none` | text after the icon, e.g. `23% · in 2 h 13 min` |
| `resetFormat` | `time`, `countdown`, `both` | `time` | the reset as `14:30`, `in 2 h 13 min`, or `14:30 · in 2 h 13 min`, in the panel, the menu bar and the page from `Open page` |
| `panelLimits` | `five_hour`, `seven_day`, `fable` | all three | the panel's rows, in this order |
| `warnAt` | `0` to `100` | `80` | from this percentage the icon and text turn yellow; `0` never |
| `refreshSeconds` | `10` and up | `60` | how often the data files are read |

A missing file or key, or a value not in the list, takes the default. With no icon and no text the pie shows.

## Updates

To get the newest version:

```sh
git -C ~/claude-limits pull
```

and `make -C ~/claude-limits install-menubar` when the menu bar item changed.

To let the clone update itself instead:

```sh
touch ~/claude-limits/.auto-update
```

Then, once a day, the next Claude Code turn pulls the newest version from the clone's `origin` in the background and rebuilds the menu bar item when its code changed. Whatever lands on `main` there runs on your Mac without you reviewing it first, with access to your Claude token. A clone with changes of its own is left alone.

## How it works

- Claude Code passes `rate_limits` to the status line on stdin; `collect` appends them to `/Users/Shared/claude-limits/<user>.js` when they are news: a later window, or the same window with a higher percentage
- a data file is a list of `S.push({...});` lines, and `sources.js` lists the files -> a page opened from disk may load a script, but not fetch or list files
- the status line input has no Fable limit, so `collect` starts `fetch-usage` in the background at most every 5 minutes: it reads Claude Code's token from the Keychain and calls `api.anthropic.com/api/oauth/usage`, the call behind `/usage`
- in the same background run, `tally` adds up the tokens in Claude Code's transcripts per hour, project and model into `<user>-tokens.js`, reading only the transcripts changed since its last run; a project is the folder a session started in, and a row never shrinks, so the numbers outlive the 30 days Claude Code keeps transcripts
- the API price is computed on the page from the prices in `limits.js`, fast mode at double; a model without a price is named under the table
- once a day `collect` starts `update` in the background: with `.auto-update` in the clone, it fast-forwards the clone to its `origin` unless the clone has changes of its own, and rebuilds the menu bar item when its code changed

**That endpoint is undocumented.** It can change or go away without notice; then the Fable tile keeps its last value and the other two carry on from the status line. The token never leaves your Mac except in that call to Anthropic, and never shows up in `ps`.

A headless run (`claude -p`) does not call the status line and records nothing.

## Old data from Usage for Claude

```sh
./import-usage-for-claude <history.jsonl>...
```

Turns the Usage for Claude app's history (in `~/Library/Group Containers/group.com.amirhayek.ClaudeUsage/`) into a data file for the page. Every run writes the file anew, so pass all history files at once.

## Test

```sh
make test
```

Needs `jq`, `node` and `swiftc`.

## License

MIT
