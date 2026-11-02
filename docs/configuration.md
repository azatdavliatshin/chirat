# Configuration

The workspace layout, `.chirat/config`, environment variables, where state
and logs live and what git tracks, and notifications. Back to the
[README](../README.md); related: [commands](commands.md),
[prompts](prompts.md), [troubleshooting](troubleshooting.md).

## Workspace layout

chirat expects a *workspace folder*: `docs/plans/`, `docs/status/`,
`.chirat/`, and the code in `repos/<repo>/` (its own git clone).
`chirat-init` creates one. The workspace sits beside the repository rather
than inside it so the repository stays free of plans, prompts, run logs and
anything that names an AI, which matters when the repository is not yours or
will be public. A single-repo mode (plans inside the code repository) is
planned but not built. An existing project with its own layout needs only the
plugin.

A new workspace gets a `CLAUDE.md` (`CLAUDE.md.in` in the template, so it is
not loaded while you work on chirat itself), a private `docs/WORKFLOW.md` for
the planning side, an empty `repos/`, and `.claude/settings.local.json` for
headless runs. It is a private git repository with routine `docs:` commits;
in `repos/*`, Claude Code commits only at a prompt's checkpoints, on its
branch, never on `main`. Pushes, in both, are yours.

## Workspace config

Everything chirat writes for itself is under `.chirat/`; everything a human
reads stays under `docs/`. An optional `.chirat/config` has `key=value` lines,
`#` comments, no quotes, paths relative to the workspace root; unknown keys
are ignored and a line without `=` is a warning.

| Key | Default | Meaning |
|---|---|---|
| `plans_dir` | `docs/plans` | where prompt files live |
| `status_dir` | `docs/status` | where status files are written and looked up |
| `default_branch` | `main` | what `after:` and the review/merge hints compare against |
| `notify_open` | empty | URL or path opened when the notification is clicked (needs `terminal-notifier` 3.x): `claude://claude.ai/project/<uuid>` opens a Project, `claude://claude.ai/chat/<uuid>` a conversation (see [support.claude.com/en/articles/14729294](https://support.claude.com/en/articles/14729294)); a value containing `'` is refused |

The config is read per run; no restart is needed.

## Environment variables

| Variable | Effect |
|---|---|
| `CHIRAT_PERMISSION_MODE` | `claude` permission mode for the watcher (default `auto`); `--permission-mode` wins |
| `CHIRAT_STOP_GRACE` | seconds the watcher waits for `claude`'s process group after TERM before KILL (default 15) |
| `CHIRAT_NOTIFY` | `0` turns notifications off |
| `CHIRAT_NOTIFY_OPEN` | `1`: a click on the notification opens the status file (and `notify_open`, if set) |
| `CHIRAT_NOTIFY_ACTIVATE` | bundle id activated on click when nothing else applies (default Claude Desktop); empty means no click action |
| `XDG_CONFIG_HOME` | the watcher's workspace list is `$XDG_CONFIG_HOME/chirat/workspaces` instead of `~/.config/chirat/workspaces` |
| `XDG_STATE_HOME` | the watcher's log is under `$XDG_STATE_HOME/chirat/` instead of `~/.local/state/chirat/` |

## State and logs

| Path | In the workspace repo | Content |
|---|---|---|
| `.chirat/config` | committed | the keys above |
| `.chirat/runs/` | committed | `.json` result and `.err` per run |
| `.chirat/LATEST` | committed | one line per finished run |
| `<plans_dir>/<topic>.prompt-N.md` | committed | the prompt; its `status` flip and `commit:` are part of the run log commit |
| `.chirat/status.log` | committed | every `status` change made by `chirat-prompt set` |
| `.chirat/lock/` | ignored | the running watcher's lock |
| `.chirat/review/` | ignored | diffs the planning chat renders for review |
| `repos/`, `.claude/`, `.DS_Store` | ignored | clones, local settings |

Outside the workspace: the list of workspaces to watch is
`~/.config/chirat/workspaces`, and `~/.local/state/chirat/` holds `watch.log`
(one line per run, plus `waiting` and `misnamed` lines; the formats are in the
header of `bin/chirat-watch`) and the watcher's own bookkeeping.

**`.chirat/runs/`.** `<topic>.prompt-N.<YYYYMMDD-HHMMSS>.json` holds the
result and metadata (not a transcript); the matching `.err` holds stderr. The
watcher commits both as `docs: run log <stem>`.

**`.chirat/LATEST`.** Each finished run appends a tab-separated line — time,
stem, final status, branch, short commit of that branch in `repos/<repo>`,
exit code or `interrupted`, seconds — committed with the run log. The chat
reads it on "check" or right after enqueueing a prompt; for the away case,
`/chirat:poll` gives it an adaptive fingerprint check instead of a fixed
timer (see the template's `docs/WORKFLOW.md`, §6).

## Status files and landing steps

Every status file ends with `## Next for the human`; for `done` it lists
review, merge, the landing steps and the prompts the merge releases. Landing
steps come from a `## Landing` section in the workspace `CLAUDE.md`, one
`- <glob or path prefix> → <command>` bullet each, printed when any touched
path matches:

```
## Landing
- plugin/ → claude plugin update chirat@chirat
- bin/chirat-watch → chirat-watch restart
```

## Notifications

When a run ends, the watcher posts a desktop notification titled
`chirat: done`, `chirat: blocked` or `chirat: failed` that says what to do
next, so no chat has to poll. macOS only; `CHIRAT_NOTIFY=0` turns it off. On
Linux nothing is sent; use `.chirat/LATEST`, `chirat-watch status`, or
`/chirat:poll` in the chat.

`terminal-notifier` 3.x (`brew install terminal-notifier`) is preferred: one
notification per workspace, and it needs its own notification permission,
granted once by launching the bundle and clicking Allow (until then every
notification is dropped; `chirat-watch doctor --online` checks):
`open "$(brew --prefix)/Cellar/terminal-notifier/<version>/terminal-notifier.app"`.

A click does one of three things: with `CHIRAT_NOTIFY_OPEN=1` it opens the
status file (and `notify_open`, if set); else it opens what `notify_open`
names; else it activates Claude Desktop (`CHIRAT_NOTIFY_ACTIVATE` overrides
the bundle id; empty means no click action). Anything `terminal-notifier`
prints or a non-zero exit goes to the run's `.err`. The `osascript` fallback
shows as "Script Editor" and ignores clicks (`CHIRAT_NOTIFY_OPEN=1` opens the
status file at once); with neither, nothing is sent. If something does not
show or click, see [troubleshooting](troubleshooting.md#notifications).
