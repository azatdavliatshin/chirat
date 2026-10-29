# relay

[![CI](https://github.com/owner/repo/actions/workflows/ci.yml/badge.svg)](https://github.com/owner/repo/actions/workflows/ci.yml)

relay connects a planning session with Claude Code through plain files in a
workspace folder, so nothing has to be copied by hand. The planning session
(a Claude Project, Cowork, or you) writes a prompt to
`docs/plans/<topic>.prompt-N.md`, with YAML front matter naming the model,
the target repo and branch, and `status: pending`. A runner — or you, typing
`/relay:next` — executes that prompt with Claude Code inside
`repos/<repo>/`, and the result lands in `docs/status/YYYY-MM-DD-<topic>.md`,
where the planning session picks it up. Code commits happen only at the
checkpoints a prompt defines, on the prompt's branch; merging and pushing
stay with the human, and a commit guard keeps workspace files out of the
repository (a workspace repository itself — one with `docs/WORKFLOW.md` at its
top level — may commit its own `docs/` files and its `.relay/` run log, except
`.relay/lock/`; in a code repository anything under `.relay/` is refused, as
are `.claude/`, `*.local.md` and the rest).

Install the plugin from this repository's marketplace, inside a Claude Code
session: `/plugin marketplace add <path-or-github>` (a local clone path, or
`owner/repo` once hosted on GitHub), then `/plugin install relay@relay`.

## Template

`template/` is the workspace layout the loop expects: a `CLAUDE.md` with the
workspace rules (stored as `CLAUDE.md.in` so it is not picked up as project
memory while you work on this repository), `docs/` (plans, status, scope,
analysis, …) with a private `docs/WORKFLOW.md`, an empty `repos/` for the
git clones, and `.claude/settings.local.json` with permissions for headless
runs (`git push` and `npm publish` denied). Create a new workspace with:

```bash
bin/relay-init <name> [dir] --name "<git name>" --email <git email> [--ssh-key <path>] [--description "<text>"]
```

It copies the template to `<dir>/<name>` (default `~/code/<name>`), fills in
the name and description, and writes a workspace `.gitconfig` with your git
identity (and `core.sshCommand` when `--ssh-key` is given). It never edits
`~/.gitconfig`; instead it prints the `includeIf` block to add there, so every
repo cloned under `repos/` picks up that identity. The workspace becomes its
own private git repository (`git init -b main`, with `repos/`, `.claude/`,
`.DS_Store` and `.relay/lock/` ignored — the template is the source of truth for
`settings.local.json`) so plans and status notes have a history; the output
shows how to attach a private remote. It refuses to overwrite an existing directory. An
existing project does not need the template — install the plugin and keep
its layout.

Two commit tiers follow from that layout. Inside `repos/*`, Claude Code
commits only at the checkpoints a prompt defines, on the prompt's branch, and
never pushes or touches `main`; you review, merge and push. In the workspace
itself, `docs:` commits are routine (`/relay:next` makes one per run) and
pushes are yours.

## Runner

`bin/relay-watch` is the headless side of the loop: a Bash script that polls
one or more workspaces for `status: pending` prompts and runs each with
`claude -p`, so a prompt written by the planning session gets executed
without anyone typing `/relay:next`. It runs on your own machine with the
`claude` login already there; there is no API key and no cloud component.

Host prerequisites: relay runs on macOS and Linux; notifications are
macOS-only (`osascript`) and degrade to nothing elsewhere. You need `claude` (logged in, with this plugin installed), `git`,
Bash 3.2 or newer, `tmux` if you want `--tmux`. `jq` is optional; the commit
guard uses it when present and falls back to `python3`. For development
also `shellcheck`.

Configuration is one file, `~/.config/relay/workspaces` (or under
`$XDG_CONFIG_HOME`): one absolute workspace path per line, `#` comments,
a leading `~` is expanded.

```
# workspaces relay-watch polls, in this order
~/code/relay
~/code/other-project   # the plugin must be installed for this user
```

Each pass takes, per workspace, the next pending prompt (lowest `N` in
`<topic>.prompt-<N><suffix>.md`, see "Prompt files"; oldest file first) and runs from the workspace root:

```
claude -p "/relay:next docs/plans/<topic>.prompt-N.md" --model <model> \
  --permission-mode auto --permission-prompts none --output-format json
```

`<model>` comes from the prompt's front matter (`sonnet` if absent). The
permission mode defaults to `auto`; override it with
`relay-watch --permission-mode <mode>` or the environment variable
`RELAY_PERMISSION_MODE` (the flag wins over the variable, the variable over
the default). `auto` is the default because a classifier reviews each action
instead of matching it against prefix rules, and prefix rules cannot match
compound commands (`a && b`, `for …; do …`, `… | tail`): under `acceptEdits`
those were denied and blocked runs that `auto` finished without a denial. To
fall back, pass `--permission-mode acceptEdits` and list every command a run
needs in `.claude/settings.local.json` of the workspace (the template already
allows `git`, `npm test`, `shellcheck`). `--permission-prompts none` stays in
both modes: anything the classifier would have asked about is denied rather
than waiting for a human who is not there, so such a run ends `blocked` or
`failed` instead of hanging. The template denies `git push` and
`npm publish`. Never use `--dangerously-skip-permissions`.

Outputs land in the workspace, under `.relay/runs/`: the JSON result
in `<topic>.prompt-N.<YYYYMMDD-HHMMSS>.json`, stderr in the matching
`.err`. They are kept in the workspace repository as the run log: the JSON
holds the result and metadata, not a transcript, and goes into the
workspace's `docs:` commits with the plans and status notes. A `.relay/lock`
directory keeps two watchers off the same workspace; a locked workspace is
skipped. If `claude` exits and the prompt is still `running` (the run died)
or still `pending` (the skill never started — plugin missing, login expired),
the watcher sets it to `failed` and says so in the `.err` file, so nothing
loops or hangs; set it back to `pending` to retry.

When a run ends, the watcher posts a desktop notification (macOS): the title is `relay: done`, `relay: blocked` or
`relay: failed`, the text names the prompt. The point is that the person
planning the work gets told, instead of a planning session polling the
workspace on a timer; a `blocked` notification says a decision is waiting
at the top of the status file. Set `RELAY_NOTIFY=0` to turn it off.

`terminal-notifier` (`brew install terminal-notifier`) is preferred: the
notification carries Claude's icon (`RELAY_NOTIFY_SENDER` overrides the bundle
id; empty means none), a new run replaces the previous notification of the
same workspace, and a click opens Claude Desktop, or whatever `notify_open`
names (see "Workspace config"). Without it the watcher falls back to
`osascript` (shown as "Script Editor", a click does nothing), and without
either nothing is sent. `RELAY_NOTIFY_OPEN=1` opens the status file on click
under `terminal-notifier` and at once under `osascript`. Claude Desktop answers
`claude://claude.ai/project/<uuid>` (a Project) and
`claude://claude.ai/chat/<uuid>` (a conversation); see
[support.claude.com/en/articles/14729294](https://support.claude.com/en/articles/14729294).

For the planning side there is one more file: after each finished run the
watcher appends a line to `.relay/LATEST` in the workspace
(tab-separated: time, prompt stem, final status, branch, short commit of that
branch in `repos/<repo>`, exit code or `interrupted`, seconds) and commits it
with the run log. The notification comes first; on "check" (or right after enqueueing) the
planning chat reads that file; for the away case `/relay:poll` gives it an
adaptive fingerprint check instead of a fixed timer — see
[template/docs/WORKFLOW.md §6](template/docs/WORKFLOW.md). `--dry-run` writes
nothing, and `waiting` / `misnamed` lines stay in the watch log only.

One line per run goes to `~/.local/state/relay/watch.log` (or under
`$XDG_STATE_HOME`) and to stdout, tab-separated: time, workspace, prompt
file, model, `claude`'s exit code, seconds.

```
2026-10-16T17:02:11+0400	/Users/me/code/relay	docs/plans/relay.prompt-3.md	sonnet	0	412
2026-10-16T17:40:03+0400	/Users/me/code/other	docs/plans/api.prompt-1.md	opus	1	58
```

Flags:

| Flag | Effect |
|---|---|
| `--once` | one pass over all workspaces, then exit 0 (also when nothing ran) |
| `--dry-run` | print the `claude` command instead of running it |
| `--interval N` | seconds between passes (default 60) |
| `--tmux` | start the watcher in a detached tmux session `relay`; refuses if it exists |
| `--version` | print the version |

### Operating the watcher

A `done` prompt is a branch waiting for your review and merge; nothing lands on `main` by itself, and the next `after:` prompt waits for that merge.

Each finished run sends a notification (`<stem> done → review <status file>, merge <branch>`; blocked and failed have their own text). `RELAY_NOTIFY_OPEN=1` also opens the status file in the default app for `.md` (off by default; `RELAY_NOTIFY=0` silences both).

The status file ends with `## Next for the human`. For `done` it lists the landing steps from the workspace `CLAUDE.md` `## Landing` section: a bullet list, each `- <glob or path prefix> → <command>`; a step is printed when any touched path matches. For example:

```
## Landing
- plugin/ → claude plugin update relay@relay
- bin/relay-watch → relay-watch restart
```

- `relay-watch status [ws…]` — read-only: watcher, tmux session, log, and per workspace the queue, the lock, the last run and a `next:` line (what you do next); exit 1 when something is `STALE`.
- `relay-watch recover [--dry-run] [ws…]` — the stale-lock recovery on demand; `--dry-run` only prints what it would do; refuses a workspace whose lock is live.
- `relay-watch logs [-n N] [-f] [ws…]` — the last N (default 20) lines of `watch.log`, for the given workspaces if any; `-f` follows.
- `relay-watch tail [-f] [ws]` — the run in progress: what the assistant says and which tools it calls, one line each (`-f` follows); times are UTC.
- `relay-watch doctor [--online]` — one `ok` / `warn` / `FAIL` line per setup check; `--online` also makes a real `claude -p` call, which is where an expired login shows up. Exit 1 on any `FAIL`.
- `relay-watch restart [--force]` — stop the watcher and start `--tmux` again with the same flags; refused while a `claude` is running unless `--force` (the prompt goes back to `pending`).

`tail` reads the transcripts Claude Code keeps under `~/.claude/projects/` and shows no tool output. `status` prints `warn:` (not `STALE`) for a `running` prompt without a lock — an interactive `/relay:next` does that.

A running watcher writes `watcher.pid` and `watcher.flags` (its flags, one per line) next to `watch.log` and removes them when it exits; `status` and `restart` read them. A bare workspace name (`aat`) selects the configured path ending in `/aat`.

Typical use: `bin/relay-watch --once --dry-run` to see what would run, then
`bin/relay-watch --tmux` and `tmux attach -t relay` to look at it.

`--tmux` is the normal way to run the watcher. A foreground watcher is one
Ctrl-C (or closed terminal) away from an interrupted run; in tmux it keeps
going when you close the terminal, and you attach only to look. If a watcher
is stopped anyway (SIGINT, SIGTERM or SIGHUP), it stops `claude`, puts the prompt it
was running back to `pending` with a note in the `.err` file, releases the
lock and logs the run with `interrupted` in the exit column; the next
watcher start picks the prompt up again.

#### Stale locks and stopping

The `.relay/lock` directory records who holds it: `watcher.pid`, `prompt` (path in
the workspace), `run` (`<stem>.<stamp>`, the name shared by the run's `.json`
and `.err`), `started`, and `claude.pid` once `claude` is up. `claude` runs in
its own process group. Before it looks for a pending prompt, every pass checks
the lock: a live `claude.pid` means the workspace is in progress and is
skipped (also when the prompt was set to `pending` by hand meanwhile — it is
not started a second time); a dead `claude.pid` or no `claude.pid`, together
with a dead `watcher.pid` (this includes an empty lock left by an older
watcher), means the lock is stale. Recovery sets the prompt back to `pending` if it still
says `running` (any other status is left alone), appends a `recovered:` note
to the run's `.err`, removes the `.json` if it is empty, removes the lock and
logs a line with `recovered` in the exit column. Liveness is `kill -0`; a dead
PID reused by an unrelated process keeps the lock looking alive until that
process exits.

On SIGINT, SIGTERM or SIGHUP (what `tmux kill-session` sends) the watcher
sends TERM to `claude`'s whole process group, KILL after 15 seconds
(`RELAY_STOP_GRACE` overrides, for tests) and waits 5 more. Only then is the
prompt put back to `pending` and the lock released. If `claude` survives even
KILL, the prompt and the lock stay and the log line says `interrupted-alive`;
the next watcher waits for that `claude`. `relay-watch recover` runs
the same recovery on demand. A lock whose `watcher.pid` is alive is never stale,
whatever `claude.pid` says: the watcher is between `claude`'s exit and releasing
the lock.

Every change of a prompt's `status` made by `relay-prompt set` is appended to
`.relay/status.log` (time, file, old, new, pid, parent pid, parent
command), so an unexpected flip can be traced to its caller.

`relay-watch install [dir]` symlinks `relay-watch` and `plugin/bin/relay-prompt`
into `dir` (default `~/.local/bin`) so both are on your `PATH`, and prints a
`PATH` hint if `dir` is not on it. It replaces existing symlinks but refuses
to overwrite anything that is not one.

### Prompt files

A prompt file is `<plans_dir>/<topic>.prompt-<N><suffix>.md`: `N` is digits and
`suffix` is empty, lowercase letters (`5b`) or a dash and `[a-z0-9-]` (`5-fix`).
Nothing else is picked up (`prompt-x.md`, `prompt-5 draft.md`). Order: `N`
numerically, plain `N` before any suffix, suffixes in byte order, then oldest
file — `5`, `5-fix`, `5b`, `6`. That is how a prompt is inserted between two
existing ones.

`relay-prompt` commands:

| Command | Effect |
|---|---|
| `get <file> <key>` / `set <file> <key> <value>` | read / write one front-matter key; a `status` change is logged to `.relay/status.log` |
| `next <ws>` | print the next pending prompt; exit 1 if none |
| `waiting <ws>` | list pending prompts held back by `after:` |
| `check <ws> <file>` | exit 0 if the file's `after:` is satisfied |
| `lint <ws>` | list `pending`/`running` files in the plans directory whose name does not match the pattern, as `<file>\t<reason>`; exit 1 if any |

`relay-watch` logs each such file once as a `misnamed` line (time, `misnamed`,
workspace, file, reason; state in `misnamed.seen` next to `waiting.seen`), next
to the `waiting` lines; renaming the file to a valid name is enough.

### Workspace config

An optional `<ws>/.relay/config` (`key=value` lines, `#` comments, no quotes)
moves the directories relay reads from and names the integration branch:

| Key | Default | Meaning |
|---|---|---|
| `plans_dir` | `docs/plans` | where prompt files live |
| `status_dir` | `docs/status` | where status files are written and looked up |
| `default_branch` | `main` | what `after:` and the review/merge hints compare against |
| `notify_open` | empty | URL or path `open`ed when the notification is clicked (needs `terminal-notifier`), e.g. `claude://claude.ai/project/<uuid>`; a value containing `'` is refused |

```
plans_dir=work/queue
status_dir=work/notes
default_branch=trunk
```

Paths are relative to the workspace root. Unknown keys are ignored and a line
without `=` is a warning, not an error. Everything relay writes for itself is
under `.relay/` (`runs/`, `LATEST`, `status.log`, `lock/`); everything a human
reads stays under `docs/`.

### Prompt front matter

| Key | Values | Meaning |
|---|---|---|
| `model` | `sonnet` \| `opus` \| `fable` | model the runner passes to `claude` (`sonnet` if absent) |
| `status` | `pending` \| `running` \| `blocked` \| `done` \| `failed` | queue state; only `pending` is picked up |
| `repo` | folder under `repos/` | required |
| `branch` | branch name | required |
| `worktree` | suffix | optional; work in `repos/<repo>-<suffix>` |
| `after` | branch name | optional; the prompt waits until that branch is merged into `default_branch` (`main`) of `repos/<repo>`. A branch that no longer exists counts as merged if a done prompt used it as `branch:` or that branch has a merge commit naming it; a branch that never existed is a planning error: the prompt keeps waiting and `relay-prompt` warns. `relay-prompt waiting <ws>` lists what is held back and why; `relay-watch` logs a `waiting` line per held prompt at most every 10 minutes. |

Planning-side rule: a prompt that depends on another prompt's branch declares
`after:` and is enqueued as `pending`; nothing is parked as `blocked` for that
reason any more. `/relay:next <file>` with an unsatisfied `after:` refuses and
ends `blocked`, so an explicit path cannot bypass the dependency.

### One-time setup notes

- **Upgrading from 0.x.** The run log moved from `docs/status/` to `.relay/`.
  In each workspace: `git mv docs/status/runs .relay/runs && git mv
  docs/status/LATEST .relay/LATEST` (only the parts that exist; `status` and
  `doctor` print a `warn:` while the old paths remain), then
  `relay-watch restart`. Nothing is migrated automatically.
- **Git identity per workspace.** `relay-init` writes `<workspace>/.gitconfig`
  and prints an `includeIf` block for `~/.gitconfig`; add it once, so every
  repo under `repos/` (and the workspace itself) commits with that identity
  without any `user.*` setting inside a repo. Headless runs rely on this:
  they commit at the checkpoints a prompt defines and nothing asks for a name.
- **Statuses.** `pending` → `running` → `done` | `blocked` | `failed`.
  `blocked` means the run needs a human decision; the question is at the top
  of the status file, and setting the prompt back to `pending` re-queues it.
  Only `pending` is ever picked up.
- **Updating the plugin.** `/plugin install` copies the plugin into Claude
  Code's cache; it is a snapshot, not a live link to the clone. After merging
  a branch that touches `plugin/`, run `claude plugin update relay@relay` (or
  `/plugin uninstall relay@relay` and `/plugin install relay@relay`) so
  sessions and the runner use the new version.
