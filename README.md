# chirat

*chirat* (*chi-RAHT*) is Tatar for "queue; one's turn".

[![CI](https://github.com/azatdavliatshin/chirat/actions/workflows/ci.yml/badge.svg)](https://github.com/azatdavliatshin/chirat/actions/workflows/ci.yml)

chirat lets you stay in the planning chat (Cowork or a Claude Project) as long
as possible and leave it only for what the chat cannot reach: merge and push.
Prompts are files, so the chat can write them; status notes and diffs come
back as files, so the chat can show them. The watcher that runs prompts with
Claude Code lives on your machine and uses your `claude` login: no API key, no
cloud component.

The loop: the chat writes `docs/plans/<topic>.prompt-N.md` → the watcher runs
it with Claude Code on a branch → `docs/status/<date>-<stem>.md` comes back →
you review in the chat and merge on your machine.

## Who it is for, and the layout it expects

chirat expects a *workspace folder*: `docs/plans/`, `docs/status/`, `.chirat/`,
and the code in `repos/<repo>/` (its own git clone). `chirat-init` creates
one. The workspace sits beside the repository rather than inside it so the
repository stays free of plans, prompts, run logs and anything that names an
AI, which matters when the repository is not yours or will be public. A
single-repo mode (plans inside the code repository) is planned but not built.
An existing project with its own layout needs only the plugin.

A new workspace gets a `CLAUDE.md` (`CLAUDE.md.in` in the template, so it is
not loaded while you work on chirat itself), a private `docs/WORKFLOW.md` for
the planning side, an empty `repos/`, and `.claude/settings.local.json` for
headless runs. It is a private git repository with routine `docs:` commits;
in `repos/*`, Claude Code commits only at a prompt's checkpoints, on its
branch, never on `main`. Pushes, in both, are yours.

## Install

Prerequisites (macOS and Linux): Bash 3.2 or newer, `git`, and `claude`
logged in. Optional: `tmux` (for `--tmux`), `jq` (the commit guard and
`chirat-watch tail` fall back to `python3`), `terminal-notifier` (see "Hearing
back"), and `shellcheck` for development.

```bash
git clone https://github.com/azatdavliatshin/chirat ~/code/chirat-src
~/code/chirat-src/bin/chirat-watch install   # chirat-watch, chirat-prompt → ~/.local/bin
```

Inside a Claude Code session, add the marketplace — a local clone path or
`azatdavliatshin/chirat` — and install the plugin; `chirat-watch doctor` then
checks the setup. The plugin brings `/chirat:next` (run one prompt file),
`/chirat:handover` (a status note for an interactive session), `/chirat:poll`
(the planning-side check-in rule), a read-only `reviewer` agent pinned to
`opus`, and the commit guard.

```
/plugin marketplace add ~/code/chirat-src      # local clone
# or, from GitHub:
/plugin marketplace add azatdavliatshin/chirat
/plugin install chirat@chirat
```

## Safety

- The watcher runs `claude -p` on **your** machine, with **your** `claude`
  login and your git credentials. The default `--permission-mode auto` means
  a classifier, not you, approves each action; with `--permission-prompts
  none` whatever it would ask about is denied and the run ends `blocked`.
- Refused in every mode, by a plugin hook: `git push` and `npm`/`pnpm`/`yarn`
  `publish`, however the command is wrapped (`git -C`, chains, `$(…)`,
  `bash -c`, `env`, …); and commits that include workspace planning files or
  `.claude/` ([Commit guard](#commit-guard)). The hook reads command text; it
  is not a sandbox. It does not cover plumbing such as `git send-pack`, `gh`
  commands that push (`gh pr create`, `gh repo sync`) or user-defined git
  aliases.
- Not sandboxed: anything else a run decides to do, in the workspace and
  beyond — installing packages, network access, deleting files. For
  repositories you do not fully trust, or on a machine with sensitive data,
  run with `--permission-mode acceptEdits` and an explicit allow list in
  `.claude/settings.local.json` ([The watcher](#the-watcher), Permissions).
- Never use `--dangerously-skip-permissions`.

## Quick start

```bash
~/code/chirat-src/bin/chirat-init demo --name "Your Name" --email you@example.com
git clone <your repo> ~/code/demo/repos/app
mkdir -p ~/.config/chirat && echo ~/code/demo >> ~/.config/chirat/workspaces
cat > ~/code/demo/docs/plans/app.prompt-1.md <<'EOF'   # normally the chat writes this
---
model: sonnet
status: pending
repo: app
branch: feat/hello
---
Add a hello target to the Makefile. One checkpoint: commit when the tests pass.
EOF
# `chirat-watch install` (see Install) put chirat-watch on PATH;
# otherwise use ~/code/chirat-src/bin/chirat-watch
chirat-watch --once --dry-run    # print the claude command it would run
chirat-watch --tmux              # start the watcher; `tmux attach -t chirat` to look
```

`chirat-init <name> [dir] --name <git name> --email <git email> [--ssh-key <path>] [--description <text>]`
copies the template to `<dir>/<name>` (default `~/code/<name>`), writes a
workspace `.gitconfig` and runs `git init -b main`; add the `includeIf` block
it prints to `~/.gitconfig` once, so headless commits under `repos/` have an
identity.

When the run ends a notification says `app.prompt-1 done → review
docs/status/<date>-app.prompt-1.md, merge feat/hello`. Read the status file
(or say "check" in the planning chat), then
`git -C ~/code/demo/repos/app merge --no-edit feat/hello`.

## Prompt files

A prompt file is `<plans_dir>/<topic>.prompt-<N><suffix>.md`: `N` is digits,
`suffix` is empty, lowercase letters (`5b`) or a dash and `[a-z0-9-]`
(`5-fix`); nothing else is picked up. Order: `N` numerically, plain `N`
first, suffixes in byte order, then oldest file — `5`, `5-fix`, `5b`, `6` —
which is how a prompt is inserted between two existing ones.

| Key | Values | Meaning |
|---|---|---|
| `model` | `sonnet` \| `opus` \| `fable` | model the watcher passes to `claude` (`sonnet` if absent) |
| `status` | `pending` \| `running` \| `blocked` \| `done` \| `failed` | queue state; only `pending` is picked up |
| `repo` | folder under `repos/` | required |
| `branch` | branch name | required |
| `worktree` | suffix | optional; work in `repos/<repo>-<suffix>` |
| `after` | branch name | optional; wait until that branch is merged into `default_branch` of `repos/<repo>`. A deleted branch counts as merged if a `done` prompt used it as `branch:` or a merge commit names it; one that never existed is a planning error: the prompt keeps waiting and `chirat-prompt` warns. A dependent prompt is enqueued `pending` with `after:`, never parked as `blocked`; `/chirat:next <file>` with an unmet `after:` ends `blocked`, so an explicit path cannot bypass it |

Statuses go `pending` → `running` → `done` | `blocked` | `failed`. A `done`
prompt is a branch waiting for your review and merge; nothing lands on `main`
by itself, and the next `after:` prompt waits for that merge. `blocked`: a
human decision is needed (the question tops the status file); set `pending` to
re-queue. `failed`: the run could not do the work. `draft` is inert, for
prompts under review (`template/docs/WORKFLOW.md` §4).

| `chirat-prompt` | Effect |
|---|---|
| `get <file> <key>` / `set <file> <key> <value>` | read / write one front-matter key; a `status` change is appended to `.chirat/status.log` (time, file, old, new, pid, parent pid, parent command), so an unexpected flip can be traced |
| `next <ws>` | print the next pending prompt; exit 1 if none |
| `waiting <ws>` | list pending prompts held back by `after:`, and why |
| `check <ws> <file>` | exit 0 if the file's `after:` is satisfied |
| `lint <ws>` | list `pending`/`running` files whose name does not match the pattern, as `<file>\t<reason>`; exit 1 if any; renaming the file is enough |

## The watcher

`chirat-watch` polls the workspaces in `~/.config/chirat/workspaces` (or under
`$XDG_CONFIG_HOME`; one absolute path per line, `#` comments, `~` expanded).
Each pass takes, per workspace, the next pending prompt and runs from the
workspace root:

```
claude -p "/chirat:next docs/plans/<topic>.prompt-N.md" --model <model> \
  --permission-mode auto --permission-prompts none --output-format json
```

**Permissions** (what this means for you: [Safety](#safety)). The default is
`auto`, because `acceptEdits` prefix rules cannot match compound commands
(`a && b`, `… | tail`) and deny them. `--permission-prompts none` stays in
every mode, so an unwatched run ends `blocked` or `failed` instead of hanging.
To fall back, pass `--permission-mode acceptEdits` (or set
`CHIRAT_PERMISSION_MODE`; the flag wins) and allow every command a run needs
in the workspace's `.claude/settings.local.json`; the template allows `git`,
`npm test`, `shellcheck` and more, and denies `git push` and `npm publish`.

**Outputs.** `.chirat/runs/<topic>.prompt-N.<YYYYMMDD-HHMMSS>.json` holds the
result and metadata (not a transcript), the matching `.err` holds stderr; the
watcher commits both as `docs: run log <stem>`. A prompt still `running`
(the run died) or `pending` (plugin missing, login expired) after `claude`
exits is set to `failed` with a note in the `.err`; set `pending` to retry.
Each run adds a line to `~/.local/state/chirat/watch.log` (or under
`$XDG_STATE_HOME`) and stdout, as do `waiting` (at most every 10 minutes) and
`misnamed` (once per file) prompts; the formats are in the script header.

| Flag / subcommand | Effect |
|---|---|
| `--once` | one pass over all workspaces, then exit 0 (also when nothing ran) |
| `--dry-run` | print the `claude` command instead of running it; writes nothing |
| `--interval N` | seconds between passes (default 60) |
| `--permission-mode M` | `claude` permission mode, passed through (default `auto`) |
| `--tmux` | start the watcher in a detached tmux session `chirat`; refuses if it exists |
| `--version` | print the version |
| `status [ws…]` | read-only: watcher, tmux session, log, and per workspace the queue, lock, last run and a `next:` line; exit 1 when something is `STALE` (a `running` prompt without a lock, as an interactive `/chirat:next` leaves, is only `warn:`). Reads `watcher.pid` and `watcher.flags`, which a running watcher keeps next to `watch.log` |
| `recover [--dry-run] [ws…]` | stale-lock recovery on demand; refuses a workspace whose lock is live |
| `logs [-n N] [-f] [ws…]` | the last N (default 20) lines of `watch.log`; `-f` follows |
| `tail [-f] [ws]` | the run in progress: assistant text and tool calls, one line each, from Claude Code's transcripts under `~/.claude/projects/`; no tool output; times in UTC |
| `doctor [--online]` | one `ok` / `warn` / `FAIL` line per setup check; `--online` also makes a real `claude -p` call, where an expired login shows up; exit 1 on any `FAIL` |
| `restart [--force]` | stop the watcher and start `--tmux` again with the same flags; refused while `claude` runs unless `--force` (the prompt goes back to `pending`) |
| `install [dir]` | symlink `chirat-watch` and `chirat-prompt` into `dir` (default `~/.local/bin`); replaces symlinks, refuses anything else, hints at `PATH` |
| `[ws…]` | workspace paths, or a bare name: `demo` selects the configured path ending in `/demo` |

**Locks and stopping.** Run with `--tmux`, not one Ctrl-C away from an
interrupted run. `.chirat/lock` keeps two watchers off one workspace and
records both PIDs; a lock whose processes are all dead is recovered on the
next pass (a `running` prompt goes back to `pending`). On
SIGINT, SIGTERM or SIGHUP (`tmux kill-session`) the watcher stops `claude`'s
process group, sets the prompt back to `pending`, releases the lock and logs
`interrupted`. The exact rules are in the header of `bin/chirat-watch`.

## Hearing back

**Notifications.** When a run ends, the watcher posts a desktop notification
titled `chirat: done`, `chirat: blocked` or `chirat: failed` that says what to
do next, so no chat has to poll. macOS only; `CHIRAT_NOTIFY=0` turns it off.
`terminal-notifier` 3.x (`brew install terminal-notifier`) is preferred: one
notification per workspace, and it needs its own notification permission,
granted once by launching the bundle and clicking Allow (until then every
notification is dropped; `chirat-watch doctor --online` checks):
`open "$(brew --prefix)/Cellar/terminal-notifier/<version>/terminal-notifier.app"`.
A click does one of three things: with `CHIRAT_NOTIFY_OPEN=1` it opens the
status file (and `notify_open`, if set); else it opens what `notify_open`
names; else it activates Claude Desktop (`CHIRAT_NOTIFY_ACTIVATE` overrides the
bundle id; empty means no click action). Anything `terminal-notifier` prints
or a non-zero exit goes to the run's `.err`. The `osascript` fallback shows as
"Script Editor" and ignores clicks (`CHIRAT_NOTIFY_OPEN=1` opens the status
file at once); with neither, nothing is sent.

**`.chirat/LATEST`.** Each finished run appends a tab-separated line — time,
stem, final status, branch, short commit of that branch in `repos/<repo>`,
exit code or `interrupted`, seconds — committed with the run log. The chat
reads it on "check" or right after enqueueing a prompt; for the away case,
`/chirat:poll` gives it an adaptive fingerprint check instead of a fixed timer
([template/docs/WORKFLOW.md §6](template/docs/WORKFLOW.md)).

**`## Next for the human`.** Every status file ends with this section; for
`done` it lists review, merge, the landing steps and the prompts the merge
releases. Landing steps come from a `## Landing` section in the workspace
`CLAUDE.md`, one `- <glob or path prefix> → <command>` bullet each, printed
when any touched path matches:

```
## Landing
- plugin/ → claude plugin update chirat@chirat
- bin/chirat-watch → chirat-watch restart
```

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

| Path | In the workspace repo | Content |
|---|---|---|
| `.chirat/config` | committed | the keys above |
| `.chirat/runs/` | committed | `.json` result and `.err` per run |
| `.chirat/LATEST` | committed | one line per finished run |
| `.chirat/status.log` | committed | every `status` change made by `chirat-prompt set` |
| `.chirat/lock/` | ignored | the running watcher's lock |
| `.chirat/review/` | ignored | diffs the planning chat renders for review |
| `repos/`, `.claude/`, `.DS_Store` | ignored | clones, local settings |

## Commit guard

A `PreToolUse` hook on every Bash call. It also refuses push and publish:
the human is the only one who pushes.

It reads every simple command in the call — split on `&&`, `||`, `;`, `|`,
`&` and newlines, including the insides of `$( … )`, backticks and
subshells — after stripping `VAR=value` and wrappers such as `env`,
`command`, `sudo`, `nohup`, `time` and `bash -c`, and walks git's global
options (`-C`, `-c`, `--no-pager`, …) to find the subcommand. Quotes are not
parsed, so a separator inside a quoted string splits too; the guard errs on
the side of checking more.

- **Push and publish, in any form:** `git push`, `git -C repos/x push`,
  `cd repos/x && git push`, `git status; git push`, `echo $(git push)`,
  `git -c k=v push --force`, `/usr/bin/git push`, and `npm publish`,
  `pnpm publish`, `yarn publish`, `yarn npm publish`. `git stash push`,
  `git log --grep push`, `echo git push` and `npm run publish-docs` pass.
- **Every `git commit`** in the call is checked against the repo it would
  commit to — the dir from `git -C`, an earlier `cd` in the chain, or the
  session's cwd.
- **Without `jq` or `python3`** the command cannot be read: the commit check
  is skipped, but any text that looks like `git … push` or `npm … publish`
  is refused (false positives are possible, and the message says so).

The workspace template's deny rules (`Bash(git push)`, `Bash(git push *)`,
`Bash(git -C * push*)`, `Bash(npm publish*)` in
`.claude/settings.local.json`) are a second layer behind the hook. Workspaces
created before this version should add the first and third rules by hand.

A commit is refused while these workspace files are staged:

| Staged path | Code repository | Workspace repository (`HEAD` has `docs/WORKFLOW.md`) |
|---|---|---|
| `.claude/`, `.planning/`, `*.local.md`, `settings.local.json`, `.DS_Store`, `.chirat/lock/` | refused | refused |
| rest of `.chirat/` | refused | allowed (the run log) |
| `docs/**/*.prompt-*.md`, `docs/WORKFLOW.md`, `docs/PARKED.md`, `docs/scope/BASELINE_*.md` | refused (other `docs/` files are fine) | allowed |

## Upgrading

- **From relay** (the earlier name; nothing is migrated automatically —
  `chirat-watch status` and `doctor` print each command until it is done, and
  the watcher skips a workspace that still has `.relay/`):
  1. Stop the old watcher: `relay-watch status` must show no live run, then
     `tmux kill-session -t relay`.
  2. Merge or pull this version into your clone.
  3. Remove the old symlinks (`rm ~/.local/bin/relay-watch
     ~/.local/bin/relay-prompt`) and run `bin/chirat-watch install`.
  4. Move the config: `mv ~/.config/relay ~/.config/chirat`; optionally the
     state too: `mv ~/.local/state/relay ~/.local/state/chirat` (with
     `$XDG_CONFIG_HOME` / `$XDG_STATE_HOME` instead of `~/.config` /
     `~/.local/state` if you set them). Rename any `RELAY_*` variable to
     `CHIRAT_*`; the old names are ignored.
  5. Per workspace: `git mv .relay .chirat && sed -i.bak
     's#^\.relay/#.chirat/#' .gitignore && rm .gitignore.bak`, and in
     `.claude/settings.local.json` change `Bash(relay-prompt *)` to
     `Bash(chirat-prompt *)`. If `.relay/lock/` exists, a run from the old
     watcher may still be live: check it first, do not move.
  6. Plugin, in Claude Code: `/plugin uninstall relay@relay`,
     `/plugin marketplace remove relay`, add the marketplace again (see
     Install), `/plugin install chirat@chirat`.
  7. The GitHub repository was renamed too; old URLs redirect, but update
     existing clones: `git remote set-url origin
     https://github.com/azatdavliatshin/chirat` (or the ssh form), and if the
     marketplace was added by GitHub name rather than a local path:
     `claude plugin marketplace remove chirat && claude plugin marketplace
     add azatdavliatshin/chirat`.
  8. `chirat-watch doctor --online`, then start the watcher:
     `chirat-watch --tmux`.
- **From 0.x** (run log moved from `docs/status/` to `.chirat/`): per workspace,
  `git mv docs/status/runs .chirat/runs && git mv docs/status/LATEST .chirat/LATEST`
  (what exists; `status` and `doctor` warn until then), `chirat-watch restart`.
- **The plugin** is a cache snapshot, not a link to the clone: after merging
  a branch that touches `plugin/`, run `claude plugin update chirat@chirat`.

## Development

```bash
bash tests/chirat-watch.sh && bash tests/chirat-init.sh && bash plugin/tests/run.sh
shellcheck bin/chirat-watch bin/chirat-init plugin/bin/chirat-prompt \
  plugin/hooks/guard-commit.sh tests/*.sh plugin/tests/run.sh
claude plugin validate plugin
```

CI (`.github/workflows/ci.yml`): all of the above on `ubuntu-latest` and
`macos-latest`, plus the suites under macOS's `/bin/bash` (3.2).

## Troubleshooting

### Notifications

**No notification, nothing in `.err`, `doctor` says `ok terminal-notifier`.**
terminal-notifier has no notification permission yet. macOS lists a
command-line tool under System Settings → Notifications only after its app
bundle has been launched once; by hand the error is `Could not request
notification permission: Notifications are not allowed for this application`.
Launch the bundle, click **Allow**, then check:
`open "$(dirname "$(dirname "$(dirname "$(readlink -f "$(command -v terminal-notifier)")")")")"`
(or `open "$(brew --prefix)/Cellar/terminal-notifier/<version>/terminal-notifier.app"`),
then `chirat-watch doctor --online` → `ok … permission granted`. `doctor` derives
the bundle path the same way and prints it when the permission is missing.

**`[!] -sender is no longer supported` in `.err`.** terminal-notifier 3.x
dropped `-sender`; chirat no longer sends it, so upgrade chirat if you see this.
Conversely `-open` is unknown to 2.x: `brew upgrade terminal-notifier`.

**The notification shows but the click does nothing.** With `notify_open`
unset the click only activates Claude Desktop. Set
`notify_open=claude://claude.ai/project/<uuid>` in `.chirat/config` (read per
run, no restart). Test a URL by hand with `open "claude://…"`; a wrong chat id
shows "That session is no longer available" in Claude Desktop. A `'` in the
value is refused (`warn:` in `.err`).

**Notifications come from "Script Editor".** The watcher did not find
terminal-notifier, often because `brew install` ran after the tmux session
started and its `PATH` is old: `chirat-watch restart`. `chirat-watch doctor`
says which notifier it sees.

**Nothing at all and `.err` is quiet.** Focus / Do Not Disturb, or the style
for terminal-notifier is "None": System Settings → Notifications →
terminal-notifier → Banners or Alerts. `CHIRAT_NOTIFY=0` in the watcher's
environment silences everything too; `chirat-watch status` prints a `notify:`
line per workspace with `CHIRAT_NOTIFY`, `CHIRAT_NOTIFY_OPEN` and `notify_open`
as seen by the shell you ran it in, so run it from the watcher's environment.

**Linux.** No desktop notifications; the loop still works through
`.chirat/LATEST`, `chirat-watch status`, or `/chirat:poll` in the chat.

### The run itself

**A prompt stays `pending`.** The watcher is not running (`chirat-watch
status`), the workspace is not in `~/.config/chirat/workspaces`, the file name
does not match the pattern (`chirat-prompt lint <ws>`, or `misnamed` in the
log), or an `after:` is unmet (`chirat-prompt waiting <ws>`).

**A run ends `failed` within seconds.** The plugin is not installed for this
user, or the `claude` login expired: `chirat-watch doctor --online`; the `.err`
names which.

**A run ends `blocked` on a permission.** `--permission-prompts none` denied
something the classifier would have asked about; the top of the status file
says what. Re-plan the prompt to avoid it, or (less safe) allow it in
`.claude/settings.local.json` and run with `acceptEdits`.

**`chirat-watch status` says `STALE`.** Run `chirat-watch recover --dry-run`
first, then `chirat-watch recover`; the rules are in the header of
`bin/chirat-watch`.

## License

MIT, see [LICENSE](LICENSE).
