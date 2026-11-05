# Commands

`chirat-watch` and `chirat-prompt`: flags, defaults, exit behavior, and how
the watcher picks the next prompt. Back to the [README](../README.md);
related: [prompts](prompts.md), [configuration](configuration.md),
[safety](safety.md), [troubleshooting](troubleshooting.md).

Terminal commands (`chirat-watch`, `chirat-prompt`, `chirat-init`) run in
your shell. The plugin's skills run inside Claude Code: `/chirat:next` (run
one prompt file), `/chirat:handover` (a status note for an interactive
session), `/chirat:poll` (the planning-side check-in rule), plus a read-only
`reviewer` agent pinned to `opus` and the [commit guard](safety.md).

## `chirat-init`

`chirat-init <name> [dir] --git-name <git name> --git-email <git email> [options]`
copies the template to `<dir>/<name>` (default `~/code/<name>`), writes a
workspace `.gitconfig`, runs `git init -b main`, commits the template as
`docs: workspace bootstrap` and prints the steps still to do, every command
ready to paste. `<name>` is kept exactly as given; `<project>-workspace` is the
recommended form. It never overwrites an existing directory, never edits
`~/.gitconfig` and asks nothing; `-h` prints all of this.

| Flag | Effect |
|---|---|
| `--git-name`, `--git-email` | required: the identity in the workspace `.gitconfig` and on the first commit (`--name`, `--email` still work as aliases) |
| `--ssh-key <path>` | `core.sshCommand = ssh -i '<path>' -o IdentitiesOnly=yes` ([several GitHub accounts](configuration.md#several-github-accounts)) |
| `--description <text>` | the paragraph at the top of the workspace `CLAUDE.md` |
| `--no-commit` | leave the template uncommitted |
| `--repo <url>` | clone into `repos/<basename without .git>`, after the first commit; repeatable. A failed clone warns, exit stays 0, and the manual `git clone` line is printed. A clone with its own `AGENTS.md` or `CLAUDE.md` gets a pointer under `## The code repository` in the workspace `CLAUDE.md` |
| `--branch <name>` | with `--repo`: clone that branch and set `default_branch=<name>`. Applies to every `--repo` ([per workspace](configuration.md#workspace-config)) |
| `--project <uuid-or-url>` | set `notify_open=claude://claude.ai/project/<uuid>`; takes the uuid or `https://claude.ai/project/<uuid>`; anything else is refused before anything is created |

If the first commit fails (a global `commit.gpgsign=true` without a usable key,
say) it warns, leaves the files staged, prints the command to retry and exits 0.

## `chirat-watch`

`chirat-watch` polls the workspaces in `~/.config/chirat/workspaces` (or under
`$XDG_CONFIG_HOME`; one absolute path per line, `#` comments, `~` expanded).
For a pending prompt it runs, from the workspace root:

```
claude -p "/chirat:next docs/plans/TOPIC.prompt-N.md" --model MODEL \
  --permission-mode auto --permission-prompts none --output-format json
```

What the permission mode means for you: [safety](safety.md#permissions).

| Flag / subcommand | Effect |
|---|---|
| `--once` | one pass over all workspaces, then exit 0 (also when nothing ran) |
| `--dry-run` | print the `claude` command instead of running it; writes nothing, including stale-lock recovery (reported as `would set … pending` / `would remove lock …`, lock left in place) and the log line (printed only) |
| `--interval N` | seconds between passes (default 60) |
| `--permission-mode M` | `claude` permission mode, passed through (default `auto`) |
| `--tmux` | start the watcher in a detached tmux session `chirat`; refuses if it exists |
| `--version` | print the version |
| `status [ws…]` | read-only: watcher, tmux session, log, and per workspace the queue, lock, last run and a `next:` line; exit 1 when something is `STALE` (a `running` prompt without a lock, as an interactive `/chirat:next` leaves, is only `warn:`). Reads `watcher.pid` and `watcher.flags`, which a running watcher keeps next to `watch.log` |
| `recover [--dry-run] [ws…]` | stale-lock recovery on demand; refuses a workspace whose lock is live |
| `logs [-n N] [-f] [ws…]` | the last N (default 20) lines of `watch.log`; `-f` follows |
| `tail [-f] [ws]` | the run in progress: assistant text and tool calls, one line each, from Claude Code's transcripts under `~/.claude/projects/`; no tool output; times in UTC |
| `doctor [--online] [ws]` | one `ok` / `warn` / `FAIL` line per setup check; `--online` also makes a real `claude -p` call, where an expired login shows up; exit 1 on any `FAIL`, 0 otherwise (`warn` does not count; same with and without `ws`). Without `ws`, one more line per registered workspace naming its `FAIL`s (`mvg: includeIf FAIL, identity FAIL`); such a `FAIL` exits 1 too. With `ws`, [that workspace's setup](#doctor-ws) too |
| `restart [--force]` | stop the watcher and start `--tmux` again with the same flags; refused while `claude` runs unless `--force` (the prompt goes back to `pending`) |
| `install [dir]` | symlink `chirat-watch` and `chirat-prompt` into `dir` (default `~/.local/bin`); replaces symlinks, refuses anything else, hints at `PATH` |
| `[ws…]` | workspace paths, or a bare name: `demo` selects the configured path ending in `/demo` |

### `doctor <ws>`

Runs the machine checks, then these for the workspace (`~` allowed; a path
without `.chirat/` is a `FAIL`). A `FAIL` on `includeIf` or `workspaces` prints
the command that fixes it.

| Check | Result | Meaning |
|---|---|---|
| `includeIf` | `ok` / `FAIL` | `~/.gitconfig`, or a file it includes, has `includeIf "gitdir:<ws>/"` with `path = <ws>/.gitconfig`; `~` and symlinks resolved, trailing `/` required |
| `identity` | `ok` / `FAIL` | `user.email` as git really sees it, in the workspace and in the first clone, is the one in `<ws>/.gitconfig`: the proof that the include works |
| `workspaces` | `ok` / `FAIL` | the workspace is listed in `~/.config/chirat/workspaces` |
| `repos` | `ok` / `warn` | at least one clone in `repos/`; a workspace may start without one |
| `default_branch` | `ok` / `warn` | the configured branch exists locally in each clone; `warn` names the clone's current branch as the likely value |
| `notify_open` | `ok` / `warn` | set, with no placeholder left |

`includeIf` can be `ok` while `identity` is `FAIL`: git itself does not follow a
symlink in the pattern, so use the physical path. `doctor` does not contact
your remotes.

### How the watcher picks the next prompt

The watcher makes one pass at a time over the registered workspaces, in the
order of `~/.config/chirat/workspaces`. For each workspace it recovers a
stale lock if there is one, asks for that workspace's next pending prompt
(order: [prompts](prompts.md#naming-and-order); prompts held back by an
unmet `after:` are skipped) and, if there is one, runs it. A run blocks the
pass until `claude` exits, so runs are strictly sequential across all
workspaces, and the first workspace in the list with a ready prompt goes
first. When a pass ends it sleeps `--interval` seconds and starts again.

### Outputs and what the watcher does after a run

`.chirat/runs/<topic>.prompt-N.<YYYYMMDD-HHMMSS>.json` holds the result and
metadata (not a transcript), the matching `.err` holds stderr; the watcher
commits both as `docs: run log <stem>`. A prompt still `running` (the run
died) or `pending` (plugin missing, login expired) after `claude` exits is set
to `failed` with a note in the `.err`; set `pending` to retry. Each run adds a
line to `~/.local/state/chirat/watch.log` (or under `$XDG_STATE_HOME`) and
stdout, as do `waiting` (at most every 10 minutes) and `misnamed` (once per
file) prompts; the formats are in the script header. More:
[configuration](configuration.md#state-and-logs).

### Locks and stopping

Run with `--tmux`, not one Ctrl-C away from an interrupted run.
`.chirat/lock` keeps two watchers off one workspace and records both PIDs
(`claude.pid` is also the id of `claude`'s process group); a lock is live
while the watcher, `claude` or anything in `claude`'s group runs — or while
the group cannot be inspected — and is recovered on the next pass only once
all of that is dead (a `running` prompt goes back to `pending`). On SIGINT,
SIGTERM or SIGHUP (`tmux kill-session`) the watcher sends TERM to `claude`'s
whole process group, waits for the *group* (up to `CHIRAT_STOP_GRACE`
seconds, default 15), sends KILL and waits again; only when nothing of the
group is left does it set the prompt back to `pending`, release the lock and
log `interrupted`. If anything survives, or the group cannot be inspected,
prompt and lock stay as they are and the log says `interrupted-alive`. The
exact rules are in the header of `bin/chirat-watch`. See also
[upgrading](upgrading.md#stopping-and-restarting-the-watcher).

## `chirat-prompt`

Reads and writes prompt front matter. It is on `PATH` after `chirat-watch
install` and while the plugin is enabled.

| Command | Effect |
|---|---|
| `get <file> <key>` / `set <file> <key> <value>` / `unset <file> <key>` | read / write / remove one front-matter key; a `status` change is appended to `.chirat/status.log` (time, file, old, new, pid, parent pid, parent command), so an unexpected flip can be traced |
| `next <ws>` | print the next pending prompt; exit 1 if none |
| `waiting <ws>` | list pending prompts held back by `after:`, and why |
| `check <ws> <file>` | exit 0 if the file's `after:` is satisfied (the reason on stdout when not; the `after_mode: done` warning on stderr when it is) |
| `lint <ws>` | list `pending`/`running` files whose name does not match the pattern, as `<file>\t<reason>`; exit 1 if any; renaming the file is enough |
