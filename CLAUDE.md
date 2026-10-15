# CLAUDE.md

## Build
```sh
./autogen.sh
./configure --enable-unittests --enable-debug-validation --enable-warnings --enable-dpdk --enable-ebpf --enable-nfqueue --enable-af-xdp --disable-sphinxbuild
make -j$(nproc)
```

A full build stores binary to ./src/suricata and takes several minutes. **Rebuild after every branch switch**.
`suricata -V` prints the commit it was built from, good to catch incorrect version run.
Suricata runs on variety of systems including Windows, Linux, FreeBSD, OpenBSD, Mac.
Be aware that each output change REQUIRES to update schema.json

## Tests

**C unit tests**:

```sh
SC_LOG_LEVEL=Debug ./src/suricata -u [-U flowbit]                # all or -U=REGEX, a PCRE filter on the test names
./src/suricata --list-unittests
```

**Rust unit tests** — from `rust/`:

```sh
cd rust && cargo test
cd rust && cargo test module::file_name::tests::test_name
```

**Suricata-Verify** — a *separate repo* checked out next to this one.
It uses `./src/suricata` and `./suricata.yaml` relative to the
**current working directory**. The SV fodler name is generally following the convention of suricata folder name plus "-verify" suffix. So if you are in Suricata folder name "suricata-dev" or "suricata" then Suricata-Verify tests can be expected in "../suricata-dev-verify/" or "../suricata-verify/" path.

```sh
python3 ../<SV foldername>/run.py                        # everything (~2500 tests, several minutes)
python3 ../<SV foldername>/run.py 'firewall/'            # a PCRE regex on test name
python3 ../<SV foldername>/run.py --debug-failed <name>  # dump stdout/stderr of failures
```

Prefer unit-tests, if they exist. Alternatively aim for Suricata-Verify. On big features, it may make sense to add full integration tests (SV) along unit-tests.
SV tests generally supply their own suricata.yaml which completely replaces the `./suricata.yaml` but some may not.
For Firewall features build SV almost exclusively, no unit tests.

**SV test anatomy** (`tests/<name>/test.yaml`): `requires:` (`min-version`, `features: [ASAN|DPDK|...]`
— checked against `--build-info`'s `Features:` line, skips cleanly if unmet; also `env`, `files`,
`script`), `args:`, `exit-code:`, `checks:` (`filter:` on eve.json fields, `shell:` grep + `expect:` (shell checks are much less preferred than eve checks!)).

Prefer native `args:` over a raw `command:` block. With no `command:`, SV builds the invocation
itself: binary, classification/reference configs, `-l`, `-c` (test dir's own `suricata.yaml` if
present, else the default one), `-r` (the test dir's one `.pcap`), and rules (its one `.rules`
file — a file named exactly `firewall.rules` auto-adds `--firewall-rules-exclusive`, which itself
implies firewall mode, no separate `--firewall` needed). Ship a local `suricata.yaml` for config
overrides (e.g. `firewall.policies.*`) instead of `--set` flags.

`command:` (+ `runner.sh`: `#!/bin/sh` / `"$@"` / `exit $?`) is only needed when a *crash* exit code
(134/139) is itself the assertion — a raw signal bypasses plain `exit-code` unless forced through a
real fork. If the assertion is `exit-code: 0` (no crash expected), skip both: native `args:` already
reports a real crash as Python's own negative signal returncode, which already fails to match 0.

Before adding a new pcap, check for an existing one to reuse: `md5sum tests/*/input.pcap | sort | uniq -c -w32 | sort -rn` finds exact duplicates already in the tree for a good hygiene).
Reference another test's pcap with `pcap: ../<test>/<file>.pcap` (`grep -rn '^pcap:' tests/*/test.yaml` for examples)
Run `pcap(ng)-check.sh` to ensure CI success.

ASAN/leak tests: gate with `requires: features: [ASAN]`.

Write checks for the CORRECT end behavior, not current buggy behavior or a diff between two pcaps as the live bug should FAIL the test now and flip to PASS once fixed.

## Formatting and code style

CI enforces clang-format on changed lines only (`.github/workflows/formatting.yml`), not on whole
files — do not reformat surrounding code.

```sh
./scripts/clang-format.sh branch           # apply to the branch's commits
./scripts/rustfmt.sh
```

Preferences:
- code not too verbose -- code comments to minimum as we avoid duplicating the information
- readability over compactness/high-degree of re-use
- generally always use curly-braces (even in simple if-statements)

## Docs

```sh
python3 -m sphinx -b html doc/userguide /tmp/docbuild
```

Keyword docs are cross-checked against the source by `scripts/check-doc-rules.py` and
`scripts/check_keyword_doc_links.py`.
Documentation should never be omitted, at the end of each change (e.g. commit) review documentation as it may need an update. Documentation ships within the commit of the code change.

The userguide docs style needs to reflect user interaction with Suricata as a security/network practicioner.
The docs, unless beneficial for their decision, are not interested in the implementation decisions, progress report, comparison to the state before the change, decision arguments and inner bits.

You also need to verify that the documentation is not overly descriptive, repetitive (aiming at the single source of truth).
Where relevant you can verbatim link parts of the codebase/docs directly to the RST docs using literalinclude directive.

## Architecture

### Packet pipeline

Explore docs as necessary but two main thread architectures are autofp and workers.
In Workers, each thread runs complete pipeline from capture through detection to logging.
In autofp, it is divided between multiple groups.

Capture modules often use source-*, runmode-*, and util-* files, detect detect-* files, logging use output-* files.
Modules are chained in thread slots, chained like: capture, decode, detect, output.
On the side, there are management threads like flow managers (FM), flow recyclers (FR), bypass manager, etc.

The engine operates as IDS, IPS, NSM/TAP (observing inline, no actions taken on the traffic), Firewall.

Split of detect files:

- `detect-engine-build.c` / `detect-engine-loader.c` — rule loading, sig-group construction
- `detect-engine-mpm.c`, `detect-engine-prefilter.c` — multi-pattern prefilter stage
- `detect-engine-content-inspection.c`, `detect-engine-inspect-buffer.c` — per-rule inspection
- `detect-engine-alert.c` — verdict/action application (`HandleFirewallRule` lives here)
- `detect-engine-analyzer.c` — `--engine-analysis` output (`rules.json`, `firewall.json`)
- `detect-parse.c` — rule *and* firewall-policy parsing (see below)
- `detect-<keyword>.c` — one file per rule keyword

  ### Rust / C Bindings

`rust/src/` holds most newer app-layer parsers (`dns`, `http2`, `ldap`, `krb`, `enip`, ...)
plus `jsonbuilder.rs`. C and Rust interop is generated in two directions:

- Rust -> C headers: `cbindgen` generates `rust/gen/rust-bindings.h`,
`rust/gen/rust-ffi.h`, and `rust/gen/htp/htp_rs.h`.
The relevant recipes are in `rust/Makefile.am` under `gen/*` and `dist/*`.
Local `rust/gen/` is ignored and normally produced/checked by the build.
If a Rust `extern "C"` API/signature changed and C does not see it, rebuild Rust/C:
`make -C rust` or `make`.

- C -> Rust bindings: `bindgen` generates tracked file `rust/sys/src/sys.rs`
from `src/bindgen.h`. If C structs/functions/macros exposed to Rust changed,
run:
`make -C rust update-bindings`

Prereqs: `cbindgen` for Rust -> C, and `bindgen` plus `rustfmt` for C -> Rust.
Install missing tools with:
`cargo install --force cbindgen`
`cargo install --force bindgen-cli`

After installing `bindgen`, rerun `./configure ...` so `HAVE_BINDGEN` is enabled;
otherwise `make -C rust update-bindings` will stay disabled in `rust/Makefile`.

Useful check:
`make -C rust check-bindgen-bindings`

### Codegen helpers

`scripts/setup-app-layer.py`, `scripts/setup-simple-detect.sh` and `scripts/setup-decoder.sh`
scaffold a new app-layer parser, detect keyword or decoder with all the registration boilerplate
wired up. Prefer them over hand-copying an existing module.

## Contributing

Follow ./git-templates/commit-template.txt when committing
PR branches are named `<type>/<ticket>-<slug>-vN` (e.g. `bug/8954-action-scope-verify-v2`), with the
version suffix bumped on each resubmission. See
https://docs.suricata.io/en/latest/devguide/contributing/contribution-process.html

Do not add any references or attributions to any AI companies or agents in the commit messages.