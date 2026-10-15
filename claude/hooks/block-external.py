#!/usr/bin/env python3
# PreToolUse hook for Bash: deny commands that publish outside this machine
# (git push, write subcommands of gh and scdev). Read-only commands pass.
# Tests: test_block_external.py

import json
import os
import re
import shlex
import sys

SHELLS = {"sh", "bash", "zsh", "dash"}
SHELL_OPTS_WITH_ARG = {"-o", "+o", "-O", "+O"}
HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
# a heredoc body is data unless a shell (or ssh) on that line reads it as commands
HEREDOC_READERS = re.compile(r"(^|[\s;&|(])(bash|sh|zsh|dash|ssh)(\s|$)")
SEPARATORS = set(";&|()\n")

GIT_BLOCKED = {"push", "send-email"}
GIT_OPTS_WITH_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env",
                     "--super-prefix"}

# gh: group -> read-only actions (None: every action is read-only)
GH_READ = {
    "pr": {"view", "list", "diff", "checks", "status", "checkout"},
    "issue": {"view", "list", "status"},
    "repo": {"view", "list", "clone"},
    "run": {"view", "list", "watch", "download"},
    "workflow": {"view", "list"},
    "release": {"view", "list", "download"},
    "gist": {"view", "list"},
    "label": {"list"},
    "cache": {"list"},
    "auth": {"status"},
    "search": None,
    "browse": None,
    "status": None,
    "help": None,
    "version": None,
}
GH_API_WRITE_FLAGS = {"-f", "-F", "--field", "--raw-field", "--input"}

# scdev: nested read-only command tree (None: anything below is read-only)
SCDEV_READ = {
    "issue": "ISSUE",
    "issues": None,
    "check": None,
    "roadmap": None,
    "reports": None,
    "completions": None,
    "config": None,
    "help": None,
    "pr": {"list": None},
    "redmine": {"versions": None, "trackers": None, "statuses": None, "groups": None,
                "roles": None, "users": {"ls": None, "get": None}},
    "gh": {"ghsa": {"ls": None}},
}

REASON = ("Blocked by luk-dev hook: publishing outside this machine (push, PR/issue writes, "
          "ticket edits) is the user's job. Stop and give the user the exact command to run.")


def strip_heredocs(command):
    out = []
    pending = []
    for line in command.split("\n"):
        if pending:
            strip_tabs, delim, keep = pending[0]
            if (line.lstrip("\t") if strip_tabs else line) == delim:
                pending.pop(0)
            elif keep:
                out.append(line)
            continue
        out.append(line)
        keep = bool(HEREDOC_READERS.search(line))
        for m in HEREDOC.finditer(line):
            pending.append((m.group(1) == "-", m.group(3), keep))
    return "\n".join(out)


def segments(command):
    lex = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    seg = []
    for tok in lex:
        if tok and set(tok) <= SEPARATORS:
            if seg:
                yield seg
            seg = []
        else:
            seg.append(tok)
    if seg:
        yield seg


def positional(args, opts_with_arg=()):
    """Non-option arguments, skipping the values of options that take one."""
    out = []
    skip = False
    for a in args:
        if skip:
            skip = False
        elif a in opts_with_arg:
            skip = True
        elif not a.startswith("-"):
            out.append(a)
    return out


def git_blocked(args):
    sub = positional(args, GIT_OPTS_WITH_ARG)
    return bool(sub) and sub[0] in GIT_BLOCKED


def gh_blocked(args):
    pos = positional(args, {"-R", "--repo", "--hostname"})
    if not pos or args[0] in ("--version", "--help", "-h"):
        return False
    group = pos[0]
    if group == "api":
        return gh_api_blocked(args[args.index("api") + 1:])
    if group not in GH_READ:
        return True
    allowed = GH_READ[group]
    if allowed is None or len(pos) < 2 or "--help" in args or "-h" in args:
        return False
    return pos[1] not in allowed


def gh_api_blocked(args):
    method = None
    write = False
    for i, a in enumerate(args):
        if a in ("-X", "--method") and i + 1 < len(args):
            method = args[i + 1].upper()
        elif a.startswith("--method="):
            method = a.split("=", 1)[1].upper()
        elif a.startswith("-X"):
            method = a[2:].upper()
        elif (a in GH_API_WRITE_FLAGS or a.startswith(("--field=", "--raw-field=", "--input="))
              or a[:2] in ("-f", "-F")):
            write = True
    pos = positional(args, {"-X", "--method", "-H", "--header", "-f", "-F", "--field",
                            "--raw-field", "--input", "-q", "--jq", "-t", "--template",
                            "--hostname", "--cache"})
    if pos and pos[0] == "graphql":
        return any(re.search(r"\bmutation\b", a, re.I) for a in args)
    if method is None:
        method = "POST" if write else "GET"
    return method != "GET"


def scdev_blocked(args):
    pos = positional(args)
    node = SCDEV_READ
    for p in pos:
        if node is None:
            return False
        if node == "ISSUE":
            # `scdev issue <id>` reads; `scdev issue [<id>] create` writes
            return "create" in pos
        if p not in node:
            return True
        node = node[p]
    return False


def shell_command_arg(args):
    """The command string of `sh [options] -c CMD`, also for clusters like -lc."""
    has_c = False
    skip = False
    for a in args:
        if skip:
            skip = False
        elif a in SHELL_OPTS_WITH_ARG:
            skip = True
        elif a.startswith("-") and not a.startswith("--"):
            has_c = has_c or "c" in a[1:]
        elif not a.startswith("--"):
            return a if has_c else None
    return None


def blocked_tokens(tokens):
    # Look at every word, not just the first, so wrappers (sudo, env, timeout, ...) and
    # `cd x && git push` style chains are covered.
    for i, tok in enumerate(tokens):
        name = os.path.basename(tok)
        rest = tokens[i + 1:]
        if name in SHELLS:
            inner = shell_command_arg(rest)
            if inner is not None:
                return blocked(inner)
        if name == "eval":
            return blocked(" ".join(rest))
        if name == "git":
            return git_blocked(rest)
        if name == "gh":
            return gh_blocked(rest)
        if name == "scdev":
            return scdev_blocked(rest)
    return False


def blocked(command):
    command = strip_heredocs(command.replace("\\\n", " "))
    return any(blocked_tokens(seg) for seg in segments(command))


# Used when the command cannot be parsed (unbalanced quotes): mirrors the allowlists roughly,
# erring on the side of denying.
FALLBACK = re.compile(
    r"\bgit\b(?![^\n;&|]*\bstash\b)[^\n;&|]*\spush\b"
    r"|\bgh\s+(?!(?:pr|issue|run|repo|release|workflow|gist|label|cache)\s+"
    r"(?:view|list|diff|checks|status|watch|download|clone)\b|search\b|auth\s+status\b"
    r"|browse\b|status\b|-)\S"
    r"|\bscdev\s+(?:pr\s+(?!list\b)|issue\b[^\n;&|]*\bcreate\b|redmine\s+(?!versions|trackers"
    r"|statuses|groups|roles|users\s+(?:ls|get)\b)|gh\s+(?!ghsa\s+ls\b))")


def main():
    data = json.load(sys.stdin)
    command = data.get("tool_input", {}).get("command", "")
    try:
        deny = blocked(command)
    except Exception:
        # unbalanced quotes etc.: fall back to a conservative pattern
        deny = bool(FALLBACK.search(command))
    if deny:
        json.dump({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                          "permissionDecision": "deny",
                                          "permissionDecisionReason": REASON}}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
