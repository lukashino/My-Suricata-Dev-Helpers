---
name: writing-sv-tests
description: Use when writing, changing, reviewing or backporting a Suricata-Verify (SV) test - test.yaml, pcaps, rules or suricata.yaml in the *-verify repo.
---

# Writing Suricata-Verify tests

A test is `tests/<name>/test.yaml` plus its pcap, rules and optional `suricata.yaml`. Start from
an existing test of the same area.

## Before writing

- Grep SV for existing coverage and state why the new test is not a duplicate. Ask before adding
  tests that were not requested: we face test explosion.
- Assert the CORRECT behavior, so the test fails on the live bug and passes once fixed. Never
  encode current (buggy) output or a diff between two runs.
- Minimal reproducer: simplest pcap, stock config, IDS mode unless the feature needs more. Don't
  tune settings (inspection windows, `decoder.*`) to make a case pass.

## Shape

```yaml
requires:
  min-version: 9           # first release with this behavior

pcap: ../other-test/input.pcap   # only to reuse an identical pcap

args:
  - -k none

checks:
  - filter:
      count: 1
      match:
        event_type: alert
        alert.signature_id: 1
  - filter:
      requires:
        lt-version: 9      # per-check gate where 8 and 9 differ
      count: 0
      match:
        event_type: drop
```

- `requires:` takes `min-version`, `lt-version`, `features: [ASAN|DPDK|...]` (matched against
  `--build-info`; unmet means a clean skip), `command` (external tools used), `env`, `files`,
  `script`, `pcap: false` (pcap-less tests). Gate ASAN/leak tests with `features: [ASAN]`.
- Prefer native `args:` over `command:`. Without `command:`, SV adds the binary, `-l`, `-c` (the
  test's own `suricata.yaml`, else the default), `-r` (the single pcap) and the single `.rules`
  file; one named `firewall.rules` is loaded via `--firewall-rules-exclusive` (implies firewall
  mode), and none at all adds `--disable-detection`. A test name containing `ips` adds
  `--simulate-ips`.
- Override config with a local `suricata.yaml`, not `--set`. It replaces the default entirely,
  so re-declare what you need (e.g. `engine-analysis:`).
- `command:` + `runner.sh` (`#!/bin/sh` / `"$@"` / `exit $?`) only when a crash exit code
  (134/139) is itself the assertion. For `exit-code: 0`, native `args:` already fails on a crash.
- `checks:` prefer `filter:` on eve.json; `shell:` + `expect:` only when EVE can't express it.

## Hygiene

- Self-contained and conventional: never write into or change another test's directory; copy
  patterns from existing tests instead of inventing mechanisms; keep it portable (Linux,
  FreeBSD, OpenBSD).
- Reuse pcaps: `find tests -name '*.pcap' -exec md5sum {} + | grep $(md5sum < new.pcap | cut -c1-32)`
  finds an identical one; reference it relative to the test dir.
- New pcaps: `file x.pcap` must say `pcap capture file` without `extensions` (OpenBSD can't read
  those); no pcapng (`tshark -F pcap -r in -w out`). `./pcap-check.sh` checks all, in ~4 min.
- Stream/reassembly tests need a real 3-way handshake: a midstream session whose protocol
  detection fails stops reassembly.
- Flaky live tests: remove the noise source or fix teardown order. Never loosen exact counts or
  add sleeps.

## Backporting a test to 8.0.x

Set the top-level `min-version` to the 8.0.x release (`AC_INIT` in `main-8.0.x`'s
`configure.ac`, e.g. `8.0.8-dev` → `8.0.8`). Split checks whose result differs between 8 and 9
into a `lt-version: 9` and a `min-version: 9` variant.

## Verify

Run the test from the Suricata root (`python3 ../<sv>/run.py --exact <name>`) on a build without
the fix (it must fail) and with it (it must pass).
