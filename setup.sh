#!/bin/bash
#
# Hook luk-dev into a suricata checkout. Run from the suricata root:
#
#   ./luk-dev/setup.sh
#
# Safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(pwd -P)"

if [ ! -f "$ROOT/src/suricata.c" ]; then
    echo "error: $ROOT is not a suricata root, run setup.sh from there" >&2
    exit 1
fi

# link <file in luk-dev> <path in suricata root>
# Relative when luk-dev sits inside the root, so the checkout can be moved as
# a whole; absolute otherwise, so the root can move independently of luk-dev.
link() {
    local src="$SCRIPT_DIR/$1"
    local dst="$ROOT/$2"
    local target
    if [[ "$src" == "$ROOT"/* ]]; then
        target="$(realpath --relative-to="$(dirname "$dst")" "$src")"
    else
        target="$src"
    fi

    if [ -L "$dst" ]; then
        if [ "$(readlink "$dst")" = "$target" ]; then
            echo "ok:      $2 -> $target"
            return
        fi
        echo "relink:  $2 -> $target (was -> $(readlink "$dst"))"
        ln -sfn "$target" "$dst"
    elif [ -e "$dst" ]; then
        echo "error: $dst exists and is not a symlink, move it away first" >&2
        exit 1
    else
        ln -s "$target" "$dst"
        echo "linked:  $2 -> $target"
    fi
}

# exclude <pattern>
# Local to this checkout (.git/info/exclude), the tracked .gitignore stays
# untouched. Order matters for negations, they must follow what they negate.
exclude() {
    if grep -qxF -- "$1" "$EXCLUDE"; then
        echo "ok:      exclude $1"
        return
    fi
    # don't glue the pattern onto a last line lacking its newline
    if [ -s "$EXCLUDE" ] && [ -n "$(tail -c1 "$EXCLUDE")" ]; then
        echo >> "$EXCLUDE"
    fi
    echo "$1" >> "$EXCLUDE"
    echo "added:   exclude $1"
}

link CLAUDE.md CLAUDE.md

if git -C "$ROOT" rev-parse --git-dir > /dev/null 2>&1; then
    EXCLUDE="$(git -C "$ROOT" rev-parse --path-format=absolute --git-path info/exclude)"
    mkdir -p "$(dirname "$EXCLUDE")"
    touch "$EXCLUDE"

    exclude '/CLAUDE.md'
    exclude 'suricata.yaml.*'
    exclude '!suricata.yaml.in'
    exclude '*.bpf'
    exclude '*.pdf'
    exclude '*.code-workspace'
else
    echo "skip:    $ROOT is not a git checkout, no excludes set"
fi
