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
  does not provide that; see step 6.

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
~/code/chirat-src/bin/chirat-init demo-workspace --git-name "Your Name" --git-email you@example.com
```

This creates `~/code/demo-workspace` (a private git repository on `main`, with
the template committed as `docs: workspace bootstrap`) with `CLAUDE.md`,
`docs/`, `.chirat/`, an empty `repos/` and `.claude/settings.local.json`. The
name is yours to choose; `<project>-workspace` keeps it apart from the code
repository. The command ends with the steps below, filled in with your real
paths, so you can paste from its output instead.

`chirat-init` never edits `~/.gitconfig`, so give the workspace its git
identity yourself, once; without it, commits under `repos/` have the wrong
author and `--ssh-key` does not apply:

```bash
git config --global --add includeIf."gitdir:$HOME/code/demo-workspace/".path "$HOME/code/demo-workspace/.gitconfig"
```

If `~/code` is a symlink, use the line `chirat-init` printed: it has the
physical path, the only one git matches.

## 3. Add your repository (terminal)

```bash
git clone URL ~/code/demo-workspace/repos/app
git -C ~/code/demo-workspace/repos/app log --oneline -1    # must show a commit
git -C ~/code/demo-workspace/repos/app branch --show-current
```

Replace `URL` with your repository's. Clone one folder per repository: the
clone must live at `repos/<repo>`, and the prompt's `repo:` is that folder
name. If its default branch is not `main`, edit
`~/code/demo-workspace/.chirat/config` (the template ships it with every key
commented out) and set:

```
default_branch=master
```

`default_branch` is what a run branches from and what `after:` and the merge
hints compare against ([configuration](configuration.md#workspace-config)).

`chirat-init` can do all of this in step 2: `--repo URL` clones (repeat it for
several), `--branch NAME` also sets `default_branch`
([commands](commands.md#chirat-init)).

## 4. Install the plugin (Claude Code)

Inside a Claude Code session, add the marketplace — the local clone path —
and install the plugin:

```
/plugin marketplace add ~/code/chirat-src
/plugin install chirat@chirat
```

(From GitHub instead of the clone: `/plugin marketplace add azatdavliatshin/chirat`.)
The plugin brings `/chirat:next`, `/chirat:handover`, `/chirat:poll`, a
read-only `reviewer` agent and the commit guard. Steps 1 and 4 are once per
machine.

## 5. Register the workspace with the watcher (terminal)

```bash
mkdir -p ~/.config/chirat && echo ~/code/demo-workspace >> ~/.config/chirat/workspaces
```

Until it is listed there, the watcher never looks at the workspace and its
prompts stay `pending`.

## 6. Connect the planning session (planning chat)

The planning session needs to read and write `~/code/demo-workspace`: it writes
prompt files into `docs/plans/` and reads status files from `docs/status/`. In
the Claude desktop app, open the workspace as the root folder of a Claude
Project (or Cowork session). If your setup differs, the requirement is the
same: the planning session must be able to read and write this folder. The
workflow instructions live in the workspace's `CLAUDE.md` and in
`docs/WORKFLOW.md`; tell the session to read them first. To land notification
clicks in that Project, set `notify_open=` in `.chirat/config`, or pass
`--project` in step 2. For this walkthrough you can skip the planning chat and
write the prompt yourself in step 8.

## 7. Check the setup (terminal)

```bash
chirat-watch doctor ~/code/demo-workspace
```

`doctor` prints one `ok` / `warn` / `FAIL` line per check: the machine (claude,
the plugin, the workspace list, tmux, `PATH`), then this workspace (the
includeIf, the identity git really uses, the watcher's list, the clones,
`default_branch`, `notify_open`). It exits 1 on any `FAIL` and prints the
command that fixes it; fix every one. `chirat-watch doctor --online`
additionally makes a real `claude -p` call (it uses your login) and shows an
expired login; run it once before the first real run.

### Optional: a private remote for the workspace

The workspace is a repository of its own; pushing it is optional and always
manual. Do it after step 2's includeIf: `--ssh-key` reaches git only through
that include. `OWNER` is your GitHub user or organization. Create an empty
private repository first (no README), then:

```bash
git -C ~/code/demo-workspace remote add origin git@github.com:OWNER/demo-workspace.git
git -C ~/code/demo-workspace push -u origin main
```

Or with the GitHub CLI, in one step:

```bash
gh repo create OWNER/demo-workspace --private --source ~/code/demo-workspace --remote origin --push
```

## 8. Write a first prompt (planning chat or terminal)

The planning session normally writes this. By hand, create
`~/code/demo-workspace/docs/plans/app.prompt-1.md` with this content:

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

## 9. Preview, then run one pass (terminal)

```bash
chirat-watch --once --dry-run    # prints the claude command it would run; writes nothing
chirat-watch --once              # runs one pass over all workspaces, then exits; no tmux needed
```

The run takes minutes; `chirat-watch tail -f` in another terminal shows what
Claude Code is doing. For daily use start the watcher in the background with
`chirat-watch --tmux` (`tmux attach -t chirat` to look at it) and leave
`--once` behind.

## 10. Read the result and merge (terminal)

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
git -C ~/code/demo-workspace/repos/app diff main..feat/hello
git -C ~/code/demo-workspace/repos/app checkout main        # only if the clone is still on feat/hello
git -C ~/code/demo-workspace/repos/app merge --no-edit feat/hello
```

Use your `default_branch` instead of `main` if it differs. A run returns the
clone to the default branch only if the tree was clean; after a failed or
dirty run it may still be on `feat/hello`, so check
`git -C ~/code/demo-workspace/repos/app status` first. chirat never pushes; push
yourself when you are satisfied.

## Where next

[Workflow](workflow.md) for how to work with it day to day,
[prompts](prompts.md) for `after:` and checkpoints,
[troubleshooting](troubleshooting.md) when a run does not go as expected.
