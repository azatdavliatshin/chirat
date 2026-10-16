# relay

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
top level — may commit its own `docs/` files; `.claude/`, `*.local.md` and the
rest are still refused).

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
own private git repository (`git init -b main`, with `repos/`, `.claude/` and
`.DS_Store` ignored — the template is the source of truth for
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

Host prerequisites: `claude` (logged in, with this plugin installed), `git`,
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
`<topic>.prompt-N.md`, oldest file first) and runs from the workspace root:

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

Outputs land in the workspace, under `docs/status/runs/`: the JSON result
in `<topic>.prompt-N.<YYYYMMDD-HHMMSS>.json`, stderr in the matching
`.err`. They are kept in the workspace repository as the run log: the JSON
holds the result and metadata, not a transcript, and goes into the
workspace's `docs:` commits with the plans and status notes. A `.lock` directory
there keeps two watchers off the same workspace; a locked workspace is
skipped. If `claude` exits and the prompt is still `running` (the run died)
or still `pending` (the skill never started — plugin missing, login expired),
the watcher sets it to `failed` and says so in the `.err` file, so nothing
loops or hangs; set it back to `pending` to retry.

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

Typical use: `bin/relay-watch --once --dry-run` to see what would run, then
`bin/relay-watch --tmux` and `tmux attach -t relay` to look at it.

`--tmux` is the normal way to run the watcher. A foreground watcher is one
Ctrl-C (or closed terminal) away from an interrupted run; in tmux it keeps
going when you close the terminal, and you attach only to look. If a watcher
is stopped anyway (SIGINT or SIGTERM), it stops `claude`, puts the prompt it
was running back to `pending` with a note in the `.err` file, releases the
lock and logs the run with `interrupted` in the exit column; the next
watcher start picks the prompt up again.

`relay-watch install [dir]` symlinks `relay-watch` and `plugin/bin/relay-prompt`
into `dir` (default `~/.local/bin`) so both are on your `PATH`, and prints a
`PATH` hint if `dir` is not on it. It replaces existing symlinks but refuses
to overwrite anything that is not one.

### One-time setup notes

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
