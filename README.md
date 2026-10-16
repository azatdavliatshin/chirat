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
