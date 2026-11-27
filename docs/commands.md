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
| `--branch <name>` | with `--repo`: clone that branch and set `default_branch=<name>`. Applies to every `--repo`. Without it, a clone that is not on `main` gets a line `default_branch.<repo>=<its branch>` in `.chirat/config`, left uncommitted ([configuration](configuration.md#workspace-config)) |
| `--project <uuid-or-url>` | set `notify_open=claude://claude.ai/project/<uuid>`; takes the uuid or `https://claude.ai/project/<uuid>`; anything else is refused before anything is created |

If the first commit fails (a global `commit.gpgsign=true` without a usable key,
say) it warns, leaves the files staged, prints the command to retry and exits 0.

## `chirat-watch`

`chirat-watch` polls the workspaces in `~/.config/chirat/workspaces` (or under
`$XDG_CONFIG_HOME`; one absolute path per line, `#` comments, `~` expanded; a path listed twice
counts once).
For a pending prompt it runs, from the workspace root:

```
claude -p "/chirat:next docs/plans/TOPIC.prompt-N.md" --model MODEL \
  --permission-mode auto --permission-prompts none --output-format json
```

What the permission mode means for you: [safety](safety.md#permissions).

| Flag / subcommand | Effect |
|---|---|
| `--once` | one pass over all workspaces, wait for every run it started, then exit 0 (also when nothing ran); a workspace the cap holds back waits for a free slot inside the pass, so under the default cap the hits run one after another in config order |
| `--dry-run` | print the `claude` command instead of running it; writes nothing, including stale-lock recovery (reported as `would set … pending` / `would remove lock …`, lock left in place) and the log line (printed only) |
| `--interval N` | seconds between passes (default 60); a finished run starts the next pass at once |
| `--max-parallel N` | at most N runs at the same time, still at most one per workspace (whole number ≥ 1, default 1); kept by `restart`. Parallel runs share the subscription's rate limits, which is why the default is 1 |
| `--permission-mode M` | `claude` permission mode, passed through (default `auto`) |
| `--tmux` | the older spelling of `start`: start the watcher in a detached tmux session `chirat`; refuses if it exists. Also takes `--once` and `--dry-run`, and does not wait for the watcher's pid |
| `--version` | print the version |
| `status [ws…]` | read-only: watcher, tmux session, log, and per workspace the queue, lock, last run and a `next:` line; exit 1 when something is `STALE` (a `running` prompt without a lock, as an interactive `/chirat:next` leaves, is only `warn:`). Reads `watcher.pid` and `watcher.flags`, which a running watcher keeps next to `watch.log` |
| `recover [--dry-run] [ws…]` | stale-lock recovery on demand; refuses a workspace whose lock is live |
| `logs [-n N] [-f] [ws…]` | the last N (default 20) lines of `watch.log`; `-f` follows |
| `tail [-f] [ws]` | the run in progress: assistant text and tool calls, one line each, from Claude Code's transcripts under `~/.claude/projects/`; no tool output; times in UTC. With several runs live and no `ws`, it refuses and lists one `chirat-watch tail <name>` per line |
| `doctor [--online] [ws]` | one `ok` / `warn` / `FAIL` line per setup check; `--online` also makes a real `claude -p` call, where an expired login shows up; exit 1 on any `FAIL`, 0 otherwise (`warn` does not count; same with and without `ws`). Without `ws`, one more line per registered workspace naming its `FAIL`s (`mvg: includeIf FAIL, identity FAIL`); such a `FAIL` exits 1 too. With `ws`, [that workspace's setup](#doctor-ws) too |
| `start [--interval N] [--max-parallel N] [--permission-mode M]` | start the watcher in the detached tmux session `chirat` and print its `watcher:` line. Refused while a watcher is running (use `restart`), and while the session exists without a live watcher (`stop` clears it); exit 1 with `watcher did not start` when it does not record its pid within 3 s |
| `stop [--force]` | stop the watcher and kill the tmux session; it also stops a watcher started in the foreground, without tmux. Prints `stopped watcher <pid> (flags: …)` and the command that starts it again with those flags. Without a recorded live watcher, a session named `chirat` is taken for it: the process in its first pane is stopped and the session closed. Refused while any run is live, every one named, unless `--force`: it stops the runs of the watcher it stops (their prompts go back to `pending` where the run could be stopped); a run whose watcher is already gone is not signaled, only named. A lock that is left (a run still live, or a stale lock for the next start's recovery) gets one line. Exit 1 when the watcher or the session is still there afterwards, or when a forced stop left a run live. More: [upgrading](upgrading.md#stopping-and-restarting-the-watcher), [safety](safety.md#stopping-the-watcher) |
| `restart [--force] [--interval N] [--max-parallel N] [--permission-mode M]` | stop the watcher and start `--tmux` again with the same flags (`--max-parallel` included); a flag given replaces the kept one of that name (`restart --max-parallel 3`), the others stay; to go back to a default, give it. Flags are checked before anything is stopped. Refused while any run is live unless `--force` (prompts are put back to `pending` where the run could be stopped) |
| `install [dir]` | symlink `chirat-watch`, `chirat-prompt` and `chirat-init` into `dir` (default `~/.local/bin`); replaces symlinks, refuses anything else, hints at `PATH`, ends with the `chirat-init` command to run next |
| `[ws…]` | workspace paths, or a bare name: `demo` selects the configured path ending in `/demo` |

### `doctor <ws>`

Runs the machine checks, then these for the workspace: a path (`~` allowed),
or a bare name: `demo` selects the configured path ending in `/demo`, unless a
folder `demo` exists in the current directory. A path without `.chirat/` is a
`FAIL`, and so is a name that matches no configured path, or several. A `FAIL` on `includeIf` or `workspaces` prints
the command that fixes it. Only the asked workspace is listed in the machine
part.

| Check | Result | Meaning |
|---|---|---|
| `includeIf` | `ok` / `FAIL` | `~/.gitconfig`, or a file it includes, has `includeIf "gitdir:<ws>/"` with `path = <ws>/.gitconfig`; `~` and symlinks resolved, trailing `/` required |
| `identity` | `ok` / `FAIL` | `user.email` (and `user.name`, and `core.sshCommand` when `<ws>/.gitconfig` sets them) as git really sees it, in the workspace and in the first clone, must come *from* `<ws>/.gitconfig` (`git config --show-origin`): the same address in `~/.gitconfig` does not pass. The proof that the include works, and that the `--ssh-key` is in effect; `warn` when git is too old for `--show-origin` |
| `workspaces` | `ok` / `FAIL` | the workspace is listed in `~/.config/chirat/workspaces` |
| `repos` | `ok` / `warn` | at least one clone in `repos/`; a workspace may start without one |
| `default_branch` | `ok` / `warn` | the branch resolved for each clone exists there locally (linked worktrees are skipped); `warn` gives the line to set, with the clone's current branch as the likely value: `default_branch.<repo>`, or `default_branch` in a workspace with one clone. `ok` lists the clones whose branch differs: `main (backend: master)` |
| `default_branch.<repo>` | `warn` | a key for which there is no clone `repos/<repo>` (a typo, say) |
| `notify_open` | `ok` / `warn` | set, with no placeholder left |

`includeIf` can be `ok` while `identity` is `FAIL`: git itself does not follow a
symlink in the pattern, so use the physical path. `doctor` does not contact
your remotes.

### How the watcher picks the next prompt

Each workspace has its own queue. The watcher makes passes over the
registered workspaces; in each pass, for each workspace, it recovers a stale
lock if there is one, asks for that workspace's next pending prompt (order:
[prompts](prompts.md#naming-and-order); prompts held back by an unmet
`after:` are skipped) and, if there is one, takes the workspace lock, starts
the run as a child process and goes on to the next workspace. So at most one
run per workspace, and several workspaces at once — up to `--max-parallel`
runs in total, **default 1**. The total counts every live run among the
registered workspaces, also one a previous watcher started (a run that kept
going after its watcher was killed); its slot is seen free on the next pass
after `--interval`, since only the watcher's own runs wake it. Parallel runs
share the subscription's rate limits, which is why the default is 1.

A pass begins where the previous one stopped: at the first workspace the cap
held back, else after the last one that started a run (round-robin over the
config list). Under the default cap two workspaces with ready prompts
therefore take turns instead of the first in the list always winning.

A workspace that has a ready prompt but was not started because of the cap is
*held*, and says so: `chirat-watch status` prints `next: wait (1 pending;
limit 1, running: relay)`, and `watch.log` (and stdout) gets

```
<time>	held	<ws>	docs/plans/x.prompt-3.md	limit=1	running=relay
```

at most once per 10 minutes per workspace, and again whenever the set of
running workspaces changes; a new wait after a run gets its own line. A
prompt waiting on an unmet `after:` is `waiting`, not `held`.

When a pass ends the watcher sleeps `--interval` seconds, but a finished run
wakes it, so the next pass starts at once. `--once` makes one pass, waits for
every run it started and exits 0; a workspace the cap holds back waits for a
free slot inside that pass (whichever run ends first), so under the default
cap `--once` runs the hits one after another in config order, as before.

### Outputs and what the watcher does after a run

`.chirat/runs/<topic>.prompt-N.<YYYYMMDD-HHMMSS>.json` holds the result and
metadata (not a transcript), the matching `.err` holds stderr; the watcher
commits both as `docs: run log <stem>`. A prompt still `running` (the run
died) or `pending` (plugin missing, login expired) after `claude` exits is set
to `failed` with a note in the `.err`; set `pending` to retry. Each run adds a
line to `~/.local/state/chirat/watch.log` (or under `$XDG_STATE_HOME`) and
stdout, as do `waiting` (at most every 10 minutes), `held` (once per wait,
see above) and `misnamed` (once per file) prompts; the formats are in the
script header. More:
[configuration](configuration.md#state-and-logs).

### Locks and stopping

Run with `chirat-watch start`, not one Ctrl-C away from an interrupted run.
`.chirat/lock` keeps two watchers off one workspace and records who holds it:
`watcher.pid` (the watcher), `runner.pid` (the run's own process) and
`claude.pid` (also the id of `claude`'s process group), plus the prompt, the
run and its start time. A lock is live while its runner, `claude` or
anything in `claude`'s group runs — or while the group cannot be inspected —
and is recovered on the next pass only once all of that is dead (a `running`
prompt goes back to `pending`). The watcher's own pid does not keep a lock
alive (it outlives every run), except for a lock written by 0.2.x, which has
no `runner.pid`. On SIGINT, SIGTERM or SIGHUP (`tmux kill-session`) the
watcher forwards the stop to every live run and waits for all of them; each
run sends TERM to `claude`'s whole process group, waits for the *group* (up
to `CHIRAT_STOP_GRACE` seconds, default 15), sends KILL and waits again; only
when nothing of the group is left does it set its prompt back to `pending`,
release its lock and log `interrupted`. If anything survives, or the group
cannot be inspected, that prompt and lock stay as they are and the log says
`interrupted-alive`. The watcher exits 130 once every run has stopped. The
exact rules, and how the wake-up and the stop signals coexist, are in the
header of `bin/chirat-watch`. See also
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
| `default-branch <ws> <repo>` | print the default branch of `repos/<repo>` ([configuration](configuration.md#workspace-config)); does not check that the branch or the clone exists |
