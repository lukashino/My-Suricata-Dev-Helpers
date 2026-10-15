#!/usr/bin/env bash
# Local mirror of the Suricata CI checks for the commits on the current branch.
# Usage: pre-push.sh [--quick] [<base-ref>]    (run from the Suricata root)
#   --quick     build only HEAD instead of every commit
#   <base-ref>  defaults to <OISF remote>/main or /main-8.0.x, whichever HEAD is closer to

set -uo pipefail

quick=0
base=""
for arg in "$@"; do
    case "$arg" in
        --quick) quick=1 ;;
        -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
        *) base="$arg" ;;
    esac
done

if [ ! -f src/suricata.c ]; then
    echo "error: run from the Suricata root" >&2
    exit 2
fi

root=$(pwd)
logs=$(mktemp -d "${TMPDIR:-/tmp}/pre-push.XXXXXX")
fails=0
warns=0
pass() { echo "PASS  $*"; }
warn() { echo "WARN  $*"; warns=$((warns + 1)); }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }

remote=$(git remote -v | awk '$3 == "(fetch)" && $2 ~ /github\.com[:\/]OISF\/suricata(\.git)?$/ { print $1; exit }')
# stale upstream refs would make upstream commits look like the branch's own
if [ -n "$remote" ] && ! git fetch -q "$remote" > "$logs/fetch.log" 2>&1; then
    warn "git fetch $remote failed, upstream refs may be stale"
fi
if [ -z "$base" ]; then
    if [ -z "$remote" ]; then
        echo "error: no OISF remote found, pass the base ref" >&2
        exit 2
    fi
    best=""
    for b in main main-8.0.x; do
        git rev-parse -q --verify "$remote/$b" > /dev/null || continue
        n=$(git rev-list --count "$remote/$b..HEAD")
        if [ -z "$best" ] || [ "$n" -lt "$best" ]; then
            base="$remote/$b"
            best=$n
        fi
    done
fi
if ! git rev-parse -q --verify "$base" > /dev/null; then
    echo "error: unknown base '$base'" >&2
    exit 2
fi

commits=$(git rev-list --reverse "$base..HEAD")
count=$(printf '%s' "$commits" | grep -c .)
orig=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
echo "== $orig: $count commit(s) on top of $base, logs in $logs"
if [ "$count" -eq 0 ]; then
    exit 0
fi
files=$(git diff --name-only "$base...HEAD")
dirty=$(git status --porcelain -uno)
if [ -n "$dirty" ]; then
    warn "uncommitted changes: the checks below see the working tree, not only the commits"
fi
backport=0
case "$base" in *main-8.0.x) backport=1 ;; esac

# Commit messages
bad_title="" ai="" no_ticket="" no_cp=""
for c in $commits; do
    short=$(git rev-parse --short "$c")
    subject=$(git log -1 --format=%s "$c")
    body=$(git log -1 --format=%B "$c")
    if ! [[ "$subject" =~ ^[A-Za-z0-9_./-]+(,\ ?[A-Za-z0-9_./-]+)*:\ .+ ]]; then
        bad_title+=" $short"
    fi
    if grep -qiE 'co-authored-by:.*(claude|anthropic)|generated with.*claude|noreply@anthropic' <<< "$body"; then
        ai+=" $short"
    fi
    grep -qE '^Ticket: ' <<< "$body" || no_ticket+=" $short"
    if [ "$backport" -eq 1 ] && ! grep -q '(cherry picked from commit ' <<< "$body"; then
        no_cp+=" $short"
    fi
done
if [ -n "$ai" ]; then
    fail "AI attribution in commit message:$ai"
fi
if [ -n "$bad_title" ]; then
    warn "title is not '<module>: <summary>':$bad_title"
fi
if [ -n "$no_ticket" ]; then
    warn "no 'Ticket:' line:$no_ticket"
fi
if [ -n "$no_cp" ]; then
    fail "backport without '(cherry picked from commit ...)':$no_cp"
fi
if [ -z "$ai$bad_title$no_ticket$no_cp" ]; then
    pass "commit messages"
fi
# scdev skips commits without a reference, so it only adds to a complete set
if [ "$backport" -eq 1 ] && [ -z "$no_cp" ] && [ -n "$remote" ] && command -v scdev > /dev/null; then
    if scdev check cp --base "$base" --main "$remote/main" > "$logs/cherry-pick.log" 2>&1; then
        pass "cherry-pick references exist in $remote/main"
    else
        fail "cherry-pick references, see $logs/cherry-pick.log"
    fi
fi

# Committed files
personal=$(grep -E '^(CLAUDE\.md|AGENTS\.md|luk-dev/|\.claude/)' <<< "$files")
if [ -n "$personal" ]; then
    fail "personal files committed: $(tr '\n' ' ' <<< "$personal")"
else
    pass "no personal files committed"
fi
toml=$(grep -E '^rust/(.*/)?Cargo\.toml(\.in)?$' <<< "$files")
if grep -qx 'rust/Cargo.lock.in' <<< "$files" && [ -z "$toml" ]; then
    warn "rust/Cargo.lock.in changed without a Cargo.toml change: build churn?"
fi

# Builds: CI builds every commit with --enable-warnings --enable-unittests --disable-lua
if [ -f config.log ] && ! grep -m1 '\$ ./configure' config.log | grep -q -- '--enable-unittests'; then
    warn "this build lacks --enable-unittests, so UNITTESTS code is not compiled as in CI (localci's commits job builds as CI does)"
fi
if [ ! -f Makefile ]; then
    fail "not configured (no Makefile), builds skipped"
elif [ "$quick" -eq 1 ] || [ "$count" -eq 1 ]; then
    if make -j"$(nproc)" > "$logs/build-HEAD.log" 2>&1; then
        pass "HEAD builds"
    else
        fail "HEAD build, see $logs/build-HEAD.log"
    fi
elif [ -n "$dirty" ]; then
    fail "uncommitted changes to tracked files: commit or stash them for per-commit builds, or use --quick"
else
    # The tree was clean before, so tracked changes made from here on are build outputs.
    trap 'git checkout -q -- . 2> /dev/null; git checkout -q "$orig"' EXIT
    built=1
    for c in $commits; do
        short=$(git rev-parse --short "$c")
        if ! git checkout -q "$c"; then
            fail "could not check out $short"
            built=0
            break
        fi
        if ! make -j"$(nproc)" > "$logs/build-$short.log" 2>&1; then
            fail "build of $short '$(git log -1 --format=%s "$c")', see $logs/build-$short.log"
            built=0
        fi
        # builds may rewrite rust/Cargo.lock.in; that churn is not part of the commit
        changed=$(git diff --name-only | grep -vx 'rust/Cargo.lock.in')
        if [ -n "$changed" ]; then
            fail "build of $short modified tracked files: $(tr '\n' ' ' <<< "$changed")"
            built=0
        fi
        git checkout -q -- .
        if [ "$built" -eq 0 ]; then
            break
        fi
    done
    trap - EXIT
    if ! git checkout -q "$orig"; then
        echo "error: left on $(git rev-parse --short HEAD), run: git checkout $orig" >&2
        exit 2
    fi
    if [ "$built" -eq 1 ]; then
        pass "every commit builds"
    fi
fi
if [ -n "$toml" ] && [ -f rust/Cargo.lock ] && ! cmp -s rust/Cargo.lock rust/Cargo.lock.in; then
    fail "rust/Cargo.lock.in is not up to date (fix: cp rust/Cargo.lock rust/Cargo.lock.in and commit it)"
fi
if grep -qE '^src/.*\.h$' <<< "$files" && [ -f rust/Makefile ]; then
    out=$(make -C rust check-bindgen-bindings 2>&1)
    if [ -f rust/sys/src/sys.rs.orig ]; then
        mv rust/sys/src/sys.rs.orig rust/sys/src/sys.rs
        fail "bindgen bindings are out of date (fix: make -C rust update-bindings, commit rust/sys/src/sys.rs)"
    elif grep -q 'Unable to check' <<< "$out"; then
        warn "bindgen not installed, bindings not checked"
    else
        pass "bindgen bindings"
    fi
fi

# C formatting, changed lines only, with CI's clang-format version
if SURICATA_BRANCH="$base" ./scripts/clang-format.sh check-branch --diffstat --show-commits \
        > "$logs/clang-format.log" 2>&1; then
    pass "clang-format"
else
    fail "clang-format, see $logs/clang-format.log (fix: SURICATA_BRANCH=$base ./scripts/clang-format.sh rewrite-branch)"
fi

# Rust: report only problems in files this branch changed
rs=$(grep -E '^rust/.*\.rs$' <<< "$files")
if [ -n "$rs" ]; then
    (cd rust && cargo fmt --check) > "$logs/rustfmt.log" 2>&1
    rc=$?
    bad=$(sed -n "s|^Diff in $root/\([^:]*\):.*|\1|p" "$logs/rustfmt.log" | sort -u | grep -Fx -f <(echo "$rs"))
    if [ -n "$bad" ]; then
        fail "rustfmt: $(tr '\n' ' ' <<< "$bad")(fix: cd rust && cargo fmt)"
    elif [ "$rc" -eq 0 ] || grep -q '^Diff in ' "$logs/rustfmt.log"; then
        pass "rustfmt (changed files)"
    else
        warn "rustfmt did not run, see $logs/rustfmt.log"
    fi
    # clippy's own toolchain first in PATH, and its own target dir: mixing them with the
    # build's toolchain fails with E0514
    clippy=$(command -v cargo-clippy)
    if [ -z "$clippy" ]; then
        warn "clippy not installed"
    elif (cd rust && PATH="${clippy%/*}:$PATH" CARGO_TARGET_DIR=target/clippy cargo clippy --workspace \
            --all-features --all-targets --message-format=short -- -D warnings) \
            > "$logs/clippy.log" 2>&1; then
        pass "clippy"
    else
        hits=$(sed -n 's|^\([^ :]*\.rs\):[0-9].*|rust/\1|p' "$logs/clippy.log" | sort -u | grep -Fx -f <(echo "$rs"))
        if [ -n "$hits" ]; then
            fail "clippy in: $(tr '\n' ' ' <<< "$hits")see $logs/clippy.log"
        else
            warn "clippy failed, but not in the changed files (or did not run), see $logs/clippy.log"
        fi
    fi
fi

# EVE schema
eve_code=$(git diff "$base...HEAD" -- src rust/src | grep -cE '^\+.*(SCJb(Set|Open|Append)|\.set_(string|uint|int|bool|float|object)\(|\.open_(object|array)\()')
if grep -qx 'etc/schema.json' <<< "$files"; then
    if ./scripts/schema-sort.py --check etc/schema.json > "$logs/schema-sort.log" 2>&1; then
        pass "schema sorted"
    else
        fail "schema not sorted (fix: ./scripts/schema-sort.py --in-place etc/schema.json)"
    fi
    if ! command -v jq > /dev/null; then
        warn "jq not installed, additionalProperties not checked"
    else
        missing=$(jq -r 'paths(objects | (.type == "object" and (has("additionalProperties") | not))) | join(".")' etc/schema.json)
        if [ -n "$missing" ]; then
            fail "schema objects without additionalProperties: $(tr '\n' ' ' <<< "$missing")"
        else
            pass "schema additionalProperties"
        fi
    fi
elif [ "$eve_code" -gt 0 ]; then
    warn "$eve_code added line(s) write EVE fields but etc/schema.json is unchanged"
fi
if grep -qE '^(etc/schema\.json|src/detect-|rust/src/.*detect)' <<< "$files" && [ -x src/suricata ]; then
    ok=1
    for mode in mapped-fields unmapped-fields unmapped-keywords; do
        python3 scripts/eve-parity.py "$mode" >> "$logs/eve-parity.log" 2>&1 || ok=0
    done
    if [ "$ok" -eq 1 ]; then
        pass "eve-parity"
    else
        fail "eve-parity, see $logs/eve-parity.log"
    fi
fi

# Userguide: CI builds it and runs the doc checks for every PR
if grep -qx 'etc/schema.json' <<< "$files"; then
    rm -rf doc/userguide/_generated    # EVE reference pages, regenerated only when missing
fi
if (cd doc/userguide && python3 -m sphinx -W -q -b html . _build/html) > "$logs/sphinx.log" 2>&1; then
    pass "userguide builds with -W"
else
    fail "userguide build, see $logs/sphinx.log"
fi
for s in check-doc-rules.py check_keyword_doc_links.py; do
    if [ ! -f "scripts/$s" ]; then
        continue
    elif python3 "scripts/$s" > "$logs/$s.log" 2>&1; then
        pass "$s"
    else
        fail "$s, see $logs/$s.log"
    fi
done

echo "== $fails failed, $warns warning(s); logs in $logs"
[ "$fails" -eq 0 ]
