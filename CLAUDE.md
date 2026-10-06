# claude-limits

## Workflow

- Every change belongs to a GitHub issue; open one first. A small fix found along the way goes into the same branch and is named in the PR description.
- Work on a branch `<issue-nr>-<short-slug>`, never on `main`.
- Once `make test` passes, open a pull request with `Closes #<nr>` and request a review from @Reconnact, who merges. Don't merge your own.
- Commits, issues and PRs are in English. A commit message is one sentence that says what changes and why, see `git log`.

## The Obsidian plugin reads this page

[claude-limits-obsidian](https://github.com/Reconnact/claude-limits-obsidian) shows this page in Obsidian. It rewrites strings in `index.html`, hooks into the page's script and hides parts of the page by selector; its CLAUDE.md lists all of it. A change to `index.html` or `limits.js` also runs the plugin's tests against this clone, from a clone of the plugin:

```sh
CLAUDE_LIMITS_REPO=<this clone> make test
```
