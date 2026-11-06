# Roadmap

What chirat is working toward. These are plans, not promises: the order
may change, items may be dropped, and nothing here has a date. Shipped
changes are listed in [CHANGELOG](../CHANGELOG.md).

Ideas and requests are welcome as GitHub issues.

## Now — 0.2.3: first public release

- A short README and separate guides ([getting started](getting-started.md),
  [workflow](workflow.md), reference pages).
- `chirat-init` that ends with pasteable next steps and an optional
  `--repo` / `--branch` / `--project` setup.
- `chirat-watch doctor <workspace>`: checks that a workspace's git
  identity, SSH key, registration and settings are actually in effect.
- A cold start on a clean machine, following only the public docs.

## Next — 0.3.0: workspaces run in parallel

Today the watcher runs one prompt at a time across all workspaces, and the
first workspace in the config goes first. In 0.3.0 each workspace gets its
own queue:

- at most one run per workspace, several workspaces at once;
- a `--max-parallel` cap, **default 1** (today's behavior until you raise
  it);
- a workspace held back by the cap says so in `status` and the log, so a
  `pending` prompt never waits without a reason.

## Then — 0.4.0: the review loop

- **Automatic review after `done`.** The watcher runs the plugin's
  read-only reviewer on the finished branch, by default with a different
  model than the one that did the work, and names the review file in the
  notification. Opt out per prompt or per workspace.
- **Machine verification.** An optional `verify=<command>` per workspace;
  the watcher (not the model) runs it on the branch after the run and
  records pass/fail in the run log and the notification.
- **A time budget per run.** An optional `timeout:` in a prompt's front
  matter; on expiry the run stops and the prompt ends `failed` with the
  reason.

## Later — under consideration

- **Single-repository mode:** plans next to the code, for people who don't
  want a separate workspace folder.
- **A planning-side skill** for draft → go → check → diff, so the loop
  works from Cowork, a Claude Project or an interactive Claude Code session
  without copying a workflow document.
- **Other executors:** whether another coding agent's CLI can stand in for
  Claude Code (the commit guard has no equivalent there, so the safety
  story would differ).
- **A more readable `chirat-watch status`:** grouped by branch, color and
  relative times on a terminal.
- **Release automation** (conventional commits, generated changelog).

## Not planned

- Shared queues, distributed execution or team coordination: chirat runs
  on one person's machine.
- Merging, pushing or publishing on your behalf: those stay your
  decisions.
