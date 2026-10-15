#!/bin/bash
#
# Hook luk-dev into a suricata checkout and set up localci next to it. Run
# from the suricata root:
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
    mkdir -p "$(dirname "$dst")"
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

if git -C "$ROOT" rev-parse --git-dir > /dev/null 2>&1; then
    EXCLUDE="$(git -C "$ROOT" rev-parse --path-format=absolute --git-path info/exclude)"
    mkdir -p "$(dirname "$EXCLUDE")"
    touch "$EXCLUDE"

    exclude '/CLAUDE.md'
    exclude '/.claude/'
    exclude '/luk-dev/'
    exclude 'suricata.yaml.*'
    exclude '!suricata.yaml.in'
    exclude '*.bpf'
    exclude '*.pdf'
    exclude '*.code-workspace'
else
    echo "skip:    $ROOT is not a git checkout, no excludes set"
fi

link CLAUDE.md CLAUDE.md
link claude/settings.json .claude/settings.json
link claude/hooks/block-external.py .claude/hooks/block-external.py
for f in "$SCRIPT_DIR"/claude/agents/*.md; do
    link "claude/agents/${f##*/}" ".claude/agents/${f##*/}"
done
for d in "$SCRIPT_DIR"/claude/skills/*/; do
    d="${d%/}"
    link "claude/skills/${d##*/}" ".claude/skills/${d##*/}"
done

# drop links to skills or agents that were removed from luk-dev
for l in "$ROOT"/.claude/agents/* "$ROOT"/.claude/skills/*; do
    if [ -L "$l" ] && [[ "$(readlink "$l")" == *luk-dev/claude/* ]] && [ ! -e "$l" ]; then
        rm "$l"
        echo "pruned:  ${l#"$ROOT"/}"
    fi
done

# localci, shared by the checkouts next to this one
LOCALCI="$(dirname "$ROOT")/localci"
if [ -e "$LOCALCI/run.py" ]; then
    echo "ok:      localci in $LOCALCI"
elif git -c core.sshCommand='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' clone -q \
        git@gitlab.oisf.net:jish/localci.git "$LOCALCI"; then
    echo "cloned:  localci into $LOCALCI"
else
    echo "warn:    localci not cloned, it needs git and SSH access to gitlab.oisf.net" >&2
fi

# Rootless podman needs a subuid/subgid range for localci's container jobs,
# once per host. A new range starts above all existing ones, so it overlaps
# no other user's.
if command -v podman > /dev/null; then
    me="$(id -un)"
    start="$({ cat /etc/subuid /etc/subgid 2> /dev/null || true; } |
        awk -F: 'NF >= 3 && $2 + $3 > m { m = $2 + $3 } END { print (m > 100000 ? m : 100000) }')"
    added=0
    for f in /etc/subuid /etc/subgid; do
        if grep -qE "^($me|$(id -u)):" "$f" 2> /dev/null; then
            echo "ok:      $f has a range for $me"
        else
            # don't glue the range onto a last line lacking its newline
            if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then
                echo | sudo tee -a "$f" > /dev/null
            fi
            echo "$me:$start:65536" | sudo tee -a "$f" > /dev/null
            echo "added:   $f $me:$start:65536"
            added=1
        fi
    done
    if [ "$added" -eq 1 ]; then
        # applies the new range; this stops the user's running containers
        podman system migrate
        echo "ran:     podman system migrate"
    fi
else
    echo "warn:    no podman, localci container jobs won't run" >&2
fi

# localci's VM jobs need qemu-system-x86_64, qemu-img and xorriso (cloud-init
# seeds). EL9 ships QEMU only as /usr/libexec/qemu-kvm, which supports the
# options localci uses with KVM, so link it under the upstream name. It has no
# TCG, so on such hosts VM jobs need a working /dev/kvm.
if command -v dnf > /dev/null; then
    pkgs=()
    command -v xorriso > /dev/null || pkgs+=(xorriso)
    command -v qemu-img > /dev/null || pkgs+=(qemu-img)
    if ! command -v qemu-system-x86_64 > /dev/null && [ ! -x /usr/libexec/qemu-kvm ]; then
        pkgs+=(qemu-kvm-core)
    fi
    # skip unreachable third-party repos instead of failing on them
    if [ "${#pkgs[@]}" -gt 0 ] &&
            sudo dnf -y -q --setopt=skip_if_unavailable=True install "${pkgs[@]}"; then
        echo "added:   ${pkgs[*]}"
    fi
fi
if ! command -v qemu-system-x86_64 > /dev/null && [ -x /usr/libexec/qemu-kvm ] &&
        [ ! -e /usr/local/bin/qemu-system-x86_64 ] && [ ! -L /usr/local/bin/qemu-system-x86_64 ]; then
    sudo ln -s /usr/libexec/qemu-kvm /usr/local/bin/qemu-system-x86_64
    echo "linked:  /usr/local/bin/qemu-system-x86_64 -> /usr/libexec/qemu-kvm"
fi
for t in qemu-system-x86_64 qemu-img xorriso; do
    if command -v "$t" > /dev/null; then
        echo "ok:      $t"
    else
        echo "warn:    no $t, localci VM jobs won't run" >&2
    fi
done
