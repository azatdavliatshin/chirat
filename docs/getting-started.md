# Getting started

From nothing to one finished task: install chirat, create a workspace,
connect the planning session, run a first prompt and review the result. Back
to the [README](../README.md); next: [workflow](workflow.md) (how to use it
day to day), [prompts](prompts.md), [commands](commands.md).

Each step says where it happens: **terminal** (your shell), **Claude Code**
(typed inside a Claude Code session) or **planning chat** (Cowork or a Claude
Project). Read [safety](safety.md) first: runs use your machine, your
`claude` login and your git credentials.

## Requirements

- macOS or Linux. Desktop notifications are macOS only; everything else
  works on both.
- Bash 3.2 or newer (macOS's default is enough), `git`, and `claude` (Claude
  Code) installed and logged in.
- Optional: `tmux` (for `--tmux`; `--once` needs none), `jq` (the commit
  guard and `chirat-watch tail` fall back to `python3` without it),
  `terminal-notifier` 3.x (macOS notifications, see
  [configuration](configuration.md#notifications)), `shellcheck` for
  development.
- A git repository of your own with at least one commit and a default
  branch. The examples call it `app`.
- A planning session that can read and write the workspace folder. chirat
  does not provide that; see step 5.

## 1. Install the commands (terminal)

```bash
git clone https://github.com/azatdavliatshin/chirat ~/code/chirat-src
~/code/chirat-src/bin/chirat-watch install   # chirat-watch, chirat-prompt → ~/.local/bin
```

`install` symlinks the two commands into `~/.local/bin` and hints if that
directory is not on your `PATH`; add it to your shell profile if so, then
open a new terminal. Check: `chirat-watch --version`. Until `PATH` is set,
use `~/code/chirat-src/bin/chirat-watch` by full path.

## 2. Create a workspace (terminal)

```bash
~/code/chirat-src/bin/chirat-init demo --name "Your Name" --email you@example.com
```

This creates `~/code/demo` (a private git repository on `main`, nothing
committed yet) with `CLAUDE.md`, `docs/`, `.chirat/`, an empty `repos/` and
`.claude/settings.local.json`. The command prints a block to add to
`~/.gitconfig`; do it once, so commits under `repos/` have an identity. It
looks like this, with your own path:

```
[includeIf "gitdir:/Users/you/code/demo/"]
    path = /Users/you/code/demo/.gitconfig
```

Then make the first commit in the workspace, as `chirat-init` suggests:

```bash
git -C ~/code/demo add -A && git -C ~/code/demo commit -m "docs: workspace bootstrap"
```

## 3. Install the plugin (Claude Code)

Inside a Claude Code session, add the marketplace — the local clone path —
and install the plugin:

```
/plugin marketplace add ~/code/chirat-src
/plugin install chirat@chirat
```

(From GitHub instead of the clone: `/plugin marketplace add azatdavliatshin/chirat`.)
The plugin brings `/chirat:next`, `/chirat:handover`, `/chirat:poll`, a
read-only `reviewer` agent and the commit guard.

## 4. Add your repository (terminal)

```bash
git clone <your repo> ~/code/demo/repos/app
git -C ~/code/demo/repos/app log --oneline -1    # must show a commit
git -C ~/code/demo/repos/app branch --show-current
```

The clone must live at `repos/<repo>`; the prompt's `repo:` is that folder
name. If its default branch is not `main`, edit `~/code/demo/.chirat/config`
(the template ships it with every key commented out) and set:

```
default_branch=master
```

`default_branch` is what a run branches from and what `after:` and the merge
hints compare against ([configuration](configuration.md#workspace-config)).

## 5. Connect the planning session (planning chat)

The planning session needs to read and write `~/code/demo`: it writes prompt
files into `docs/plans/` and reads status files from `docs/status/`. In the
Claude desktop app, `chirat-init` suggests a Claude Project (or Cowork
session) whose root folder is the workspace. If your setup differs, the
requirement is the same: the planning session must be able to read and write
this folder. The workflow instructions live in the workspace's `CLAUDE.md`
and in `docs/WORKFLOW.md`; tell the session to read them first. For this
walkthrough you can skip the planning chat and write the prompt yourself in
step 7.

## 6. Register the workspace and check the setup (terminal)

```bash
mkdir -p ~/.config/chirat && echo ~/code/demo >> ~/.config/chirat/workspaces
chirat-watch doctor
```

`doctor` prints one `ok` / `warn` / `FAIL` line per check (claude, the
plugin, the workspace list, tmux, `PATH`) and exits 1 on any `FAIL`. Run it
once the steps above exist, and fix every `FAIL`. `chirat-watch doctor
--online` additionally makes a real `claude -p` call (it uses your login)
and shows an expired login; run it once before the first real run.

## 7. Write a first prompt (planning chat or terminal)

The planning session normally writes this. By hand, create
`~/code/demo/docs/plans/app.prompt-1.md` with this content:

```
---
model: sonnet
status: pending
repo: app
branch: feat/hello
---
Add a file `HELLO.md` at the repository root containing one line, "Hello".
One checkpoint: commit it on this branch with the message "docs: add HELLO".
```

`status: pending` runs on its own the next time the watcher passes;
`status: draft` waits until you set `pending`. The front matter keys are in
[prompts](prompts.md).

## 8. Preview, then run one pass (terminal)

```bash
chirat-watch --once --dry-run    # prints the claude command it would run; writes nothing
chirat-watch --once              # runs one pass over all workspaces, then exits; no tmux needed
```

The run takes minutes; `chirat-watch tail -f` in another terminal shows what
Claude Code is doing. For daily use start the watcher in the background with
`chirat-watch --tmux` (`tmux attach -t chirat` to look at it) and leave
`--once` behind.

## 9. Read the result and merge (terminal)

When the run ends a notification (macOS) or `chirat-watch status` says what
happened. The result:

- the prompt's `status:` is `done` (or `blocked` / `failed`, see
  [troubleshooting](troubleshooting.md));
- the branch `feat/hello` exists in `repos/app` with the commit;
- a status file `docs/status/<date>-app.prompt-1.md` and a run log in
  `.chirat/runs/`.

An illustration of a status file (not a recorded run):

```
# app.prompt-1

## Done
- Added HELLO.md; committed on feat/hello.

## Not done
- Nothing.

## Branch
feat/hello 1a2b3c4

## Next for the human
1. Review this file and `git -C repos/app diff main..feat/hello`.
2. `git -C repos/app merge --no-edit feat/hello`
```

Review, then merge into the right base branch, naming it explicitly:

```bash
git -C ~/code/demo/repos/app diff main..feat/hello
git -C ~/code/demo/repos/app checkout main        # only if the clone is still on feat/hello
git -C ~/code/demo/repos/app merge --no-edit feat/hello
```

Use your `default_branch` instead of `main` if it differs. A run returns the
clone to the default branch only if the tree was clean; after a failed or
dirty run it may still be on `feat/hello`, so check
`git -C ~/code/demo/repos/app status` first. chirat never pushes; push
yourself when you are satisfied.

## Where next

[Workflow](workflow.md) for how to work with it day to day,
[prompts](prompts.md) for `after:` and checkpoints,
[troubleshooting](troubleshooting.md) when a run does not go as expected.
