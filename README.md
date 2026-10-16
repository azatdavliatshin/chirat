# relay

relay connects a planning session with Claude Code through plain files in a
workspace folder, so nothing has to be copied by hand. The planning session
(a Claude Project, Cowork, or you) writes a prompt to
`docs/plans/<topic>.prompt-N.md`, with YAML front matter naming the model,
the target repo and branch, and `status: pending`. A runner — or you, typing
`/relay:next` — executes that prompt with Claude Code inside
`repos/<repo>/`, and the result lands in `docs/status/YYYY-MM-DD-<topic>.md`,
where the planning session picks it up. Commits and pushes stay with the
human; a commit guard keeps workspace files out of the repository.

Install the plugin from this repository's marketplace, inside a Claude Code
session: `/plugin marketplace add <path-or-github>` (a local clone path, or
`owner/repo` once hosted on GitHub), then `/plugin install relay@relay`.

## Template

`template/` is the workspace layout the loop expects: a `CLAUDE.md` with the
workspace rules, `docs/` (plans, status, scope, analysis, …) with a private
`docs/WORKFLOW.md`, an empty `repos/` for the git clones, and
`.claude/settings.local.json` with permissions for headless runs (`git push`
and `npm publish` denied). Create a new workspace with:

```bash
bin/relay-init <name> [dir] --name "<git name>" --email <git email> [--ssh-key <path>] [--description "<text>"]
```

It copies the template to `<dir>/<name>` (default `~/code/<name>`), fills in
the name and description, and writes a workspace `.gitconfig` with your git
identity (and `core.sshCommand` when `--ssh-key` is given). It never edits
`~/.gitconfig`; instead it prints the `includeIf` block to add there, so every
repo cloned under `repos/` picks up that identity. It refuses to overwrite an
existing directory. An existing project does not need the template — install
the plugin and keep its layout.
