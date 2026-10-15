---
name: pre-push-checks
description: Use when a Suricata change is about to be reported as done, before the user pushes or opens a PR, or when asked whether a branch will pass CI.
---

# Pre-push checks

Runs what Suricata CI checks on a PR, locally, for the commits on the current branch: commit
messages, cherry-pick references (8.0.x), committed personal files, a build of every commit,
clang-format (CI's version, changed lines), rustfmt and clippy (changed Rust files), the EVE
schema, eve-parity, and the userguide with `-W` plus the doc checks.

From the Suricata root:

```sh
bash ${CLAUDE_SKILL_DIR}/pre-push.sh [--quick] [<base-ref>]
```

- The base defaults to the OISF remote's `main` or `main-8.0.x`, whichever the branch is closer to.
- Building every commit takes minutes: run it in the background. `--quick` builds only HEAD, for
  iterating; the final run is without it.
- Per-commit builds need a clean tracked tree and check out each commit: until the script ends,
  don't edit files, run git, start localci jobs or dispatch agents in this checkout. It returns to the branch.
- It fetches the OISF remote first, so the base is current.

Fix each FAIL in the commit it belongs to (`git commit --fixup=<sha>`, then
`git rebase --autosquash --autostash $(git merge-base <base> HEAD)`, which squashes without moving
the branch to a newer base) and rerun. Pass every WARN on to the user. Report
the summary lines and the log directory.

Not covered: unit tests and SV tests (run the ones for the change) and CI's other jobs and build
configurations: use the running-local-ci skill for those.
