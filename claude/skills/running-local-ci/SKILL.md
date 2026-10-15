---
name: running-local-ci
description: Use when a Suricata change needs CI jobs that pre-push-checks does not cover (ASAN with instrumented Rust, scan-build, FreeBSD or OpenBSD builds, SV live tests, per-commit builds with CI's configure flags), or when asked to run local CI.
---

# Local CI (localci)

`../localci/run.py`, next to the checkouts, runs Suricata's GitHub CI jobs in podman containers or
QEMU VMs, half of them through the in-tree `qa/ci/*.sh` scripts that CI runs too. Options and
internals: `../localci/README.md`.

From the Suricata root:

```sh
../localci/run.py --list
../localci/run.py rust-asan --sv-dir ../<sv>                     # job-name substring; --job <exact>
../localci/run.py commits --env BASE_REF=$(git rev-parse <remote>/main)  # main-8.0.x for backports
```

| Job | Covers | Runs on |
|---|---|---|
| `commits` | every commit builds, `--enable-warnings --enable-unittests` | main, 8.0.x |
| `rust-asan` | ASAN with Rust, `--enable-debug`, whole SV suite | main |
| `scan-build` | clang static analysis | main |
| `freebsd` | FreeBSD build and SV | main |
| `openbsd` | OpenBSD build and unit tests, no SV (CI on main runs SV too) | main, 8.0.x |
| `sv-live` | SV `live/` tests with DPDK and XDP, in a VM | main, 8.0.x |

- It tests the committed HEAD (`git archive`) and refuses uncommitted changes to tracked files;
  `--sv-dir` must be committed too. Without it, SV is upstream `master`, cached in
  `localci/_cache/`.
- The `qa/ci/` jobs (rust-asan, scan-build, freebsd) need a `main`-based HEAD: `main-8.0.x` has
  no `qa/ci/` (untracked `qa/ci/Makefile*` left by a main build don't count). So on 8.0.x no job
  builds with `--enable-debug` or ASAN, which CI does: code inside `SCLogDebug()` needs one debug
  build elsewhere.
- Give `commits` its `BASE_REF` as a SHA: it resolves the base in a local clone, where `github/*`
  refs don't exist and `origin/main` is this checkout's (possibly stale) local `main`.
- Jobs take 5 to 30 minutes, more on a first run (OpenBSD installs itself first): run them in the
  background. Different jobs can run in parallel. Work trees and reports are in
  `localci/_builds/<checkout dir>/<job>/`.
- Each job copies HEAD when it starts. Until every selected job has started, don't run
  pre-push-checks, commit or rebase in this checkout; use a separate `git worktree` for that.
- `luk-dev/setup.sh` clones localci and sets up podman and the VM tools. If container pulls fail
  with `insufficient UIDs or GIDs`, rerun it; if it reports the ranges as ok, run
  `podman system migrate` (it stops your running containers).
