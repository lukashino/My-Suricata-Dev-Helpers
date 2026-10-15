# CLAUDE.md

## Working rules

- **NEVER push, open/comment on PRs or issues, or post anything externally**
  Local commits and branches are fine; the user publishes.
- A question, "discuss" or "explain" is not a go-ahead: answer it, don't edit code.
- Reproduce a failure/identified security bug before fixing it.
  For before/after numbers, name the baseline (upstream,
  the user's uncommitted draft, or your result).
- Report review findings as a readable list (not JSON), separating real bugs from design
  questions. Check the docs before calling documented behavior a bug.
- Give the exact path or command for every deliverable; don't leave it only in a scratchpad.

## Build

Dev build, from a clean checkout:

```sh
./autogen.sh
./configure --enable-unittests --enable-warnings --enable-dpdk --enable-ebpf --enable-nfqueue SPHINX_BUILD=no
make -j$(nproc)
```

- `--enable-debug-validation` (`DEBUG_VALIDATE_*` checks) and `--enable-unittests` are mutually
  exclusive; configure fails on both. `SCLogDebug()` needs `--enable-debug`, then
  `SC_LOG_LEVEL=Debug` (`SC_LOG_OP_FILTER=<regex>` narrows it).
- A full build takes several minutes. **Rebuild (autogen to make) after every branch switch or rebase.**
  `./src/suricata -V` shows the commit seen by the last `./configure`, not the last build.
- Checkouts are often perf builds (`-O3`, no unit tests): check `--build-info` and
  `grep -m1 '\$ ./configure' config.log` before relying on `-u`; ask before reconfiguring.
- Suricata runs on Linux, FreeBSD, OpenBSD, macOS and Windows: guard OS-specific code, keep a fallback.
- Every EVE output change MUST update `etc/schema.json` (sorted:
  `./scripts/schema-sort.py --in-place etc/schema.json`) and the userguide.

## Tests

Prefer unit tests where the area already has them, otherwise Suricata-Verify (SV); big features
may warrant both. Firewall features: SV almost exclusively.

```sh
./src/suricata -u -U '<pcre>'           # C unit tests; -U filters names
./src/suricata --list-unittests
cd rust && cargo test [module::file::tests::name]
```

**Suricata-Verify** is a separate repo next to this one, named after this directory plus
`-verify` (`suricata-dev` → `../suricata-dev-verify`). Run it from the Suricata root, as it
uses `./src/suricata` and `./suricata.yaml` from the cwd.

```sh
python3 ../<sv>/run.py -q <name> [<name>...]   # SUBSTRING match, not regex; no name = all ~3000
python3 ../<sv>/run.py --exact <name>
python3 ../<sv>/run.py --debug-failed <name>   # print stdout/stderr of failures
sudo -E ../<sv>/live/run.py [--exact] <name>   # live capture, for what pcaps can't cover
```

- If PASSED, FAILED and SKIPPED are all 0, nothing matched: that is not a pass.
- Before blaming your change for SV failures, rule out version skew: SV should be on the matching
  branch or current upstream, and the Suricata branch not older than SV.

### Writing SV tests (`tests/<name>/test.yaml`)

- Before adding a test, grep SV for existing coverage and state why yours is not a duplicate.
  Ask before adding tests that were not requested: we face test explosion.
- Assert the CORRECT behavior, so the test fails on the live bug and passes once fixed. Never
  encode current (buggy) output or a diff between two runs.
- Minimal reproducer: simplest pcap, stock config, IDS mode unless the feature needs more. Don't
  tune settings (inspection windows, `decoder.*`) to make a case pass.
- Self-contained and conventional: never write into or change another test's directory; copy
  patterns from existing tests instead of inventing mechanisms; keep it portable (Linux,
  FreeBSD, OpenBSD).
- `requires:` takes `min-version`, `lt-version`, `features: [ASAN|DPDK|...]` (matched against
  `--build-info`; unmet means a clean skip), `command` (external tools used), `env`, `files`,
  `script`, `pcap: false` (pcap-less tests). Gate ASAN/leak tests with `features: [ASAN]`.
- Prefer native `args:` over `command:`. Without `command:`, SV adds the binary, `-l`, `-c` (the
  test's own `suricata.yaml`, else the default), `-r` (the single pcap) and the single `.rules`
  file; one named `firewall.rules` is loaded via `--firewall-rules-exclusive` (implies firewall
  mode), and none at all adds `--disable-detection`. A test name containing `ips` adds
  `--simulate-ips`. Override config with a local `suricata.yaml`, not `--set`; it replaces the
  default entirely, so re-declare what you need (e.g. `engine-analysis:`).
- `command:` + `runner.sh` (`#!/bin/sh` / `"$@"` / `exit $?`) only when a crash exit code
  (134/139) is itself the assertion. For `exit-code: 0`, native `args:` already fails on a crash.
- `checks:` prefer `filter:` on eve.json; `shell:` + `expect:` only when EVE can't express it.
- Behavior that differs between 8 and 9 gets a per-check gate: `requires: {lt-version: 9}` (or
  `min-version: 9`) inside that `filter:`. Backports set the test's top-level `min-version` to
  the 8.0.x release and split such checks.
- Reuse pcaps: `find tests -name '*.pcap' -exec md5sum {} + | grep $(md5sum < new.pcap | cut -c1-32)`
  finds an identical one; reference it relative to the test dir (`pcap: ../<test>/<file>.pcap`).
- New pcaps: `file x.pcap` must say `pcap capture file` without `extensions` (OpenBSD can't read
  those); no pcapng (`tshark -F pcap -r in -w out`). `./pcap-check.sh` checks all, in ~4 min.
- Stream/reassembly tests need a real 3-way handshake: a midstream session whose protocol
  detection fails stops reassembly.
- Flaky live tests: remove the noise source or fix teardown order. Never loosen exact counts or add sleeps.

## Commits and pre-push checks (mirror CI)

- One logical change per commit, and each commit must build: CI builds every commit
  (`git rebase -x 'make -j$(nproc)' <base>`). Keep a fix minimal, tests included,
  split independent fixes, and fold follow-ups into the commit they belong to
  (`git commit --fixup=<sha>`, then `git rebase --autosquash --autostash <base>`).
- Stage explicit paths, never `git add -A` / `git add .`: checkouts hold untracked personal files
- clang-format applies to changed lines only; never reformat surrounding code. Use the script:
  it picks clang-format-17 like CI (the system one is newer and formats differently). It diffs
  against `origin/main` (`origin/main-8.0.x` on 8.0.x), so name the base when the remote differs:
  ```sh
  SURICATA_BRANCH=github/main ./scripts/clang-format.sh check-branch    # github/main-8.0.x for backports
  SURICATA_BRANCH=github/main ./scripts/clang-format.sh rewrite-branch  # fix inside each commit
  ```
- Rust: `cd rust && cargo fmt && cargo clippy --workspace --all-features --all-targets -- -D warnings`.
- `./scripts/schema-sort.py --check etc/schema.json`
- Docs, `main` only: `python3 scripts/check-doc-rules.py` (doc example rules must load) and
  `python3 scripts/check_keyword_doc_links.py`.
- The remaining CI checks (schema `additionalProperties`, `scripts/eve-parity.py`, ...) are in
  `.github/workflows/{builds,docs}.yml`.

## Code style

- Concise code; comments only where they add what the code does not say.
- Readability over compactness or maximal reuse.
- Always use curly braces, even around a single-statement `if`.
- Use Suricata-native helper functions/wrappers, instead of using native function calls when applicable, e.g., 
  use the `threads.h` wrappers (`SCMutex*`, `SCCond*`, `SCSpin*`), not raw pthread calls.
- Scaffold new modules with `scripts/setup-app-layer.py`, `scripts/setup-simple-detect.sh` or
  `scripts/setup-decoder.sh` instead of copying an existing one.

## Docs

Docs ship in the same commit as the code; re-check them at the end of every change.
Build like CI: `cd doc/userguide && python3 -m sphinx -W -q -b html . <scratchpad>/docbuild`.

- Write for a security/network practitioner (rule writer or person deploying Suricata on live network) using Suricata: what it does, how to configure it, what it outputs.
  Leave out implementation details, design rationale, history ("previously", "now") and progress notes unless they affect a user's decision.
- Concise and non-repetitive, one source of truth; pull code/config in verbatim with
  `literalinclude` where it helps.
- When relevant, e.g., behavior change, add a note to the upgrade guide
## Review

Besides classic bugs (`/code-review`), check that:

- code comments and the userguide match the actual behavior (see Docs);
- the change is right in every mode (IDS, IPS, NSM/TAP, firewall), runmode (workers, autofp) and
  capture method, respects the extensions (pcap-log, file extraction, transactions, IP
  reputation, ...), and changes no behavior that was not asked for;
- tests are compact, readable and unique, covering the most behavior with the fewest tests.

## Development process

- Two maintained lines: 9 on `main`, 8.0.x on `main-8.0.x`. Changes land on `main` first and are
  backported only on request.
- Backports are `git cherry-pick -x` of the `main` commits, ideally clean, otherwise minimally
  adapted (e.g. inline `main`-only helpers). **NEVER change detection, runtime or configuration
  behavior on 8.0.x unless explicitly asked.** Verify the references with
  `scdev check cp --base github/main-8.0.x --main github/main`.
- Redmine tickets are separately created so the backport commits should have ticket numbers updated.
- Provide full explanation and options if the backport is not clean.

When the prompt says **ultrathink**, run the full multi-agent workflow, with every subagent
(implementers and reviewers) on the most capable model available (Fable or Opus):

1. Clarify the assignment (superpowers:brainstorming) until it is unambiguous, then write the
   plan (superpowers:writing-plans).
2. Lead with tests (TDD, usually SV); here they count as requested, but must still be unique.
   Consider edge cases across modes, runmodes, capture methods, extensions and plugins.
3. Implement the plan.
4. Review with a **fresh** agent following "Review"; repeat implement → fresh review until clean.

## Tools and environment

- `gh`; `scdev` (authenticated OISF helper; use it read-only, as `pr create`/`next-rev` and
  `issue create` publish): `scdev issue <id> [--json]` reads a Redmine ticket with comments
  (anonymous Redmine API returns 401). Use `--json` for relations: the text output prints the
  wrong side of incoming ones.
- OISF remote names vary per checkout (often `github`, not `origin`): check `git remote -v`.
- HOME is an sshfs mount shared by several hosts; checkouts live on local disk. Python packages
  (e.g. scapy) are in user site-packages, which `python3 -I` and `sudo` (HOME=/root) hide.
- `sudo` is passwordless on the dev hosts (live tests, DPDK hugepages); its outputs are root-owned.
- You can use sudo as necessary, install packages, or make changes, albeit try sudoless paths first. Installing a package that helps is better than writing same funcitonality from scratch.

## Architecture

- Runmodes: **workers** (each thread runs capture → decode → stream → detect → output) and
  **autofp** (capture/decode threads hand packets to flow-pinned workers). Stages are thread
  modules chained as slots (`tm-threads.c`); management threads (flow manager/recycler, bypass
  manager, stats) run alongside. Modes: IDS, IPS, NSM/TAP (inline, takes no action), firewall.
- Detection: `detect-engine-{build,loader,mpm,prefilter,content-inspection,inspect-buffer}.c`;
  `detect-engine-alert.c` applies verdicts/actions incl. firewall (`HandleFirewallRule`);
  `detect-engine-analyzer.c` writes `--engine-analysis` (`rules.json`, `firewall.json`);
  `detect-parse.c` parses rules and firewall policies; `detect-<keyword>.c` one per keyword.
- YAML: a key defined again later (in the same file or via `include:`) replaces the earlier
  section wholesale, with no deep merge; a dotted key (`a.b.c: v`) overrides only that leaf.

### Rust ↔ C

`rust/src/` holds most newer app-layer parsers and `jsonbuilder.rs`.

- Rust → C: the cbindgen headers in `rust/gen/` are untracked build output. If C doesn't see a
  changed `extern "C"` signature, run `make`.
- C → Rust: bindgen generates the **tracked** `rust/sys/src/sys.rs` from `src/bindgen.h`; after
  changing anything exposed there run `make -C rust update-bindings` (check:
  `make -C rust check-bindgen-bindings`). Needs `cargo install --force cbindgen bindgen-cli` and
  `rustfmt`; re-run `./configure` after installing bindgen, else `HAVE_BINDGEN` stays off.

## Contributing

- Commits follow `git-templates/commit-template.txt`: `<module>: <summary>` title, a body that
  explains why, `Ticket: <redmine id>`. Never mention AI companies or agents in commit messages:
  no `Co-Authored-By` or "Generated with" lines.
- Branches: `<type>/<ticket>-<slug>-vN` (e.g. `bug/8954-action-scope-verify-v2`), backports
  `backport-8.0.x/<type>/<ticket>-<slug>-vN`; bump `vN` on each resubmission. See
  https://docs.suricata.io/en/latest/devguide/contributing/contribution-process.html
- When drafting PR text, link the SV PR via `SV_BRANCH=`. Keep ticket titles neutral: describe
  the issue, don't dramatize its impact.
