# Safety

What a chirat run can and cannot do on your machine, which guards exist and
what they do not see. Back to the [README](../README.md); related:
[commands](commands.md) (the watcher and its flags),
[configuration](configuration.md), [troubleshooting](troubleshooting.md).

## What a run can do

- The watcher runs `claude -p` on **your** machine, with **your** `claude`
  login and your git credentials. The default `--permission-mode auto` means
  a classifier, not you, approves each action; with `--permission-prompts
  none` whatever it would ask about is denied and the run ends `blocked`.
- Refused in every mode, by a plugin hook: `git push` and `npm`/`pnpm`/`yarn`
  `publish`, however the command is wrapped (`git -C`, chains, `$(…)`,
  `bash -c`, `env`, …); and commits that include workspace planning files or
  `.claude/` ([Commit guard](#commit-guard)). The hook reads the **text** of
  each Bash command; it is not a sandbox. What it is for and what it does
  not see: [What it is for](#what-it-is-for).
- Not sandboxed: anything else a run decides to do, in the workspace and
  beyond — installing packages, network access, deleting files. For
  repositories you do not fully trust, or on a machine with sensitive data,
  run with `--permission-mode acceptEdits` and an explicit allow list in
  `.claude/settings.local.json` ([Permissions](#permissions)).
- Never use `--dangerously-skip-permissions`.
- You are responsible for what is merged and pushed: review the diff and the
  status file, then merge and push yourself.
- The watcher needs no server of its own, but Claude Code still talks to its
  service with your login.

## Permissions

The default is `auto`, because `acceptEdits` prefix rules cannot match
compound commands (`a && b`, `… | tail`) and deny them.
`--permission-prompts none` stays in every mode, so an unwatched run ends
`blocked` or `failed` instead of hanging. To fall back, pass
`--permission-mode acceptEdits` (or set `CHIRAT_PERMISSION_MODE`; the flag
wins) and allow every command a run needs in the workspace's
`.claude/settings.local.json`; the template allows `git`, `npm test`,
`shellcheck` and more, and denies `git push` and `npm publish`.

## Commit guard

A `PreToolUse` hook on every Bash call. It also refuses push and publish:
the human is the only one who pushes.

### What it is for

The guard catches the ordinary ways an agent's Bash command commits in a
repository it did not mean to, or pushes or publishes — the command shapes
runs actually produce — and refuses what it cannot read. It is defense in
depth, not a sandbox: it does not stand up to a command written to get past
it.

What holds regardless of the hook: `git push` and `npm publish` are denied in
the workspace's `.claude/settings.local.json` ([Permissions](#permissions);
the deny rules are listed below), and the human merges every
branch.

**Known limitations.** The hook reads the text of each Bash command, so it
does not see:

- the contents of script files and programs it runs — `bash run.sh`, a
  Python or Node program, an `npm` script, a Makefile target can do
  anything, including push (a shell fed from a pipe, heredoc or stdin is
  refused instead, because its code is not in the command text);
- git plumbing such as `git send-pack`, `gh` commands that push (`gh pr
  create`, `gh repo sync`), and user-defined git aliases;
- a function that commits, called through another function under a
  different git environment (`f() { git commit …; }; g() { f; }; GIT_DIR=… g`);
- a function run as a `trap` handler after the environment changed
  (`trap f EXIT; export GIT_DIR=…`).

`plugin/tests/guard-corpus.sh` runs every line of its corpus against a real
shell and fails when the guard allows something harmful; documented gaps are
the lines marked `known`.

It reads every simple command in the call with a small shell-word lexer:
`"…"`, `'…'`, `\x`, `$'…'`, comments and here-documents are understood, so a
quoted path with spaces or `&`/`;` is one word and `git commit -m "a; git
push"` is a commit, not a push; redirections (`>`, `2>&1`, `<<<`, `<<`) are
recognized only unquoted, so `git -C '>dir' commit` is a commit in `>dir`.
Commands are split on `&&`, `||`, `;`, `|`, `&` and newlines, including the
insides of `$( … )`, backticks, `${x:-$(…)}`, subshells, `bash -c '…'` /
`eval` bodies and unquoted heredoc bodies — after stripping `VAR=value` and
wrappers such as `env`, `command`, `sudo`, `nohup` and `time` — and git's
global options (`-C`, `-c`, `--git-dir`, `--work-tree`, `--no-pager`, …) are
walked to find the subcommand. Nothing is expanded or executed: a variable,
substitution, glob or `~user` leaves a word *unresolved*.

**Fail closed.** When the guard cannot tell which repository a commit targets
— an unresolved `-C` / `--git-dir` / `--work-tree` value, a `cd` to an
unresolved dir (or `cd -`), a literal path that is not a git repository — or
cannot tell what a git command does (`git $SUB`), or cannot parse the command
(unbalanced quotes, unterminated `$(`), it refuses with a one-line reason
(`chirat: cannot tell which repository this commits to; run git from the
repository directory`). A false refusal costs a retry; a false pass would
break the promise. The same holds for any `cd` the hook cannot follow — in a
loop, a function, a `trap` — the commit's target is unknown and the command
is refused.

**Two things are tracked, not one.** `-C` resolves an unknown *directory*:
after a `cd` the hook lost, `git -C <repo> commit` is checked against
`<repo>` and passes if it is clean. It does not resolve an unknown *shell*:
after code the hook could not read has run in the same shell — `source` /
`.`, `eval` of a variable, a function it could not follow, `shopt -s
expand_aliases`, an `export` / `unset` of a `GIT_*` variable it could not
carry — functions, aliases and the environment may all have changed, and
**every** later `git`, `npm`, `pnpm` or `yarn` command in that shell is
refused, with or without `-C`. Start a fresh command. A subshell, a pipeline
member, a background job or a `bash -c` body keeps its unknown state to
itself. `export GIT_DIR=<repo>/.git` (or `GIT_WORK_TREE`) with a literal
value is carried like `GIT_DIR=… git commit`, so the commit is checked where
it really goes. Every other `GIT_*` variable is not supported by the commit
check: as a prefix (`GIT_INDEX_FILE=x git commit`, also `GIT_AUTHOR_DATE=…`)
it refuses that commit — the reason says so and points at git's own option
(`--date`, `-m`) — and exported it makes the shell unknown. Some of these
move git's layout or the very index the guard inspects; others are
harmless, and a small allow-list of verified-harmless names may come later
(an allow-list, not a deny-list). A function whose body commits, called
directly under any git environment its body was read without — exported, a
prefix (`GIT_DIR=… f`), an `env` argument, resolved or not — is refused too.
A function is judged by all of its properties together — it moves, it
commits, it changes the shell, it runs a bare shell — and by the call's
environment; none of them hides another.

- **Push and publish, in any form:** `git push`, `git -C repos/x push`,
  `cd repos/x && git push`, `git status; git push`, `echo $(git push)`,
  `git -c k=v push --force`, `/usr/bin/git push`, and `npm publish`,
  `pnpm publish`, `yarn publish`, `yarn npm publish`. `git stash push`,
  `git log --grep push`, `echo git push` and `npm run publish-docs` pass.
- **Every `git commit`** in the call is checked against the repo it would
  commit to — the dir from `git -C`, `--git-dir` / `--work-tree` (also
  `GIT_DIR` / `GIT_WORK_TREE`, as a prefix or exported), an earlier `cd` /
  `pushd` / `env -C` in the chain, or the session's cwd.
- **Shells fed from a pipe, heredoc or stdin** are refused: `… | sh`,
  `… | bash -`, `bash -s`, `bash <<EOF`, `sh <<<"$X"`, `bash < file`, also
  behind `sudo`, `env`, `timeout`, `xargs` or inside `bash -c`. They run code
  the hook cannot see. A shell given a script file (`bash tests/run.sh`) is
  allowed, and the file is not read — see [Safety](#safety).
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
