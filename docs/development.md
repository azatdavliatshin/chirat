# Development

Tests, linting, plugin validation, platforms and CI, and how reports against
the commit guard are handled. Back to the [README](../README.md); related:
[safety](safety.md), [commands](commands.md).

Planned work is in the [roadmap](roadmap.md); requests go to GitHub issues.

Run from the root of the clone:

```bash
bash tests/chirat-watch.sh && bash tests/chirat-init.sh && bash plugin/tests/run.sh
shellcheck bin/chirat-watch bin/chirat-init plugin/bin/chirat-prompt \
  plugin/hooks/guard-commit.sh tests/*.sh plugin/tests/*.sh
claude plugin validate plugin
```

CI (`.github/workflows/ci.yml`): all of the above on `ubuntu-latest` and
`macos-latest`, plus the suites under macOS's `/bin/bash` (3.2).

Reports against the commit guard: a new bypass is first added to
`plugin/tests/guard-corpus.txt`. It is fixed when the fix is local to one
rule; otherwise the line is marked `known` and the shape is listed under
[Known limitations](safety.md#what-it-is-for). The hook is not extended to model more
of the shell in a patch release.
