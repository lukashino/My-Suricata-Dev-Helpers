#!/usr/bin/env python3
# Run: python3 luk-dev/claude/hooks/test_block_external.py

import json
import os
import subprocess
import sys

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "block-external.py")

BLOCK = [
    "git push",
    "git push gh-mine HEAD",
    "git -C ../suricata-verify push origin x",
    "git --git-dir=.git push",
    "git -c push.default=current push",
    "cd /tmp && git push",
    "make && git push -f gh-mine br",
    "sudo -E git push",
    "env GIT_TRACE=1 git push",
    "/usr/bin/git push",
    "bash -c 'git push gh-mine'",
    "sh -c \"cd x; git push\"",
    "git status\ngit push",
    "git send-email *.patch",
    "gh pr create --fill",
    "gh pr comment 123 -b hi",
    "gh pr review 123 --approve",
    "gh pr merge 1",
    "gh issue create -t x",
    "gh issue comment 5 -b x",
    "gh release create v1",
    "gh repo fork",
    "gh api -X POST repos/OISF/suricata/issues/1/comments -f body=x",
    "gh api repos/OISF/suricata/pulls/1/reviews -f event=COMMENT",
    "gh api --method PATCH repos/x/y",
    "gh api graphql -f query='mutation { addComment(input:{}) { clientMutationId } }'",
    "gh workflow run ci.yml",
    "gh some-extension do",
    "scdev pr create",
    "scdev pr next-rev 123",
    "scdev pr stage 1 2",
    "scdev issue create --subject x",
    "scdev issue 123 create",
    "scdev redmine set-cve 1 CVE-1",
    "scdev redmine users rm bob",
    "scdev redmine admin auto-lock",
    "git push gh-mine 'unterminated",
    "git \\\npush gh-mine HEAD",
    "git -C ../suricata-dev-verify \\\n  push origin x",
    "bash -lc 'git push'",
    "bash -e -c 'git push'",
    "sh -xc \"gh pr create\"",
    "bash <<'EOF'\ngit push gh-mine\nEOF",
    "gh api -XPOST repos/x/y/issues",
    "gh api repos/x/y/issues -fbody=x",
    "gh api repos/x/y/issues -Fbody=x",
    "gh api repos/x/y/issues --raw-field=a=b",
    "echo \"it's\" && gh workflow run ci.yml",
    "echo it's; gh workflow run x",
    "echo it's; git -C x push",
    "echo it's; scdev pr create",
    "git push>/dev/null",
    "git push 2>&1 | tail -3",
    ">log git push",
    "scdev pr create 2>&1 | tee log",
    "scdev pr create &>/dev/null",
    "scdev pr create -- --help",
    "diff <(scdev pr list) <(scdev pr create)",
]

ALLOW = [
    "git status",
    "git log --grep=push",
    "git commit -m 'fix git push handling'",
    "git commit -m \"push: x\" && git log -1",
    "git fetch github",
    "git pull --rebase github main",
    "git rebase --autosquash github/main",
    "git remote -v",
    "git config --get push.default",
    "grep -rn 'git push' docs/",
    "ls; echo done",
    "gh pr view 123 --json commits",
    "gh pr list -R OISF/suricata",
    "gh pr diff 1",
    "gh pr checks 1",
    "gh issue view 9",
    "gh run view 1 --log-failed",
    "gh api repos/OISF/suricata/pulls/1",
    "gh api -X GET repos/OISF/suricata/pulls",
    "gh api graphql -f query='query { viewer { login } }'",
    "gh search prs --repo OISF/suricata flow",
    "gh auth status",
    "gh --version",
    "gh pr --help",
    "scdev issue 8968",
    "scdev issue 8968 --json",
    "scdev issues --assigned-to me",
    "scdev check cp --base github/main-8.0.x --main github/main",
    "scdev pr list --links",
    "scdev redmine versions",
    "scdev redmine users ls",
    "scdev gh ghsa ls",
    "scdev roadmap 8.0.8",
    "scdev --help",
    "make -j8 && ./src/suricata -V",
    "echo it's fine",
    "git commit -F - <<'EOF'\nfix: x\n\ngh pr create was not used. It's fine.\nEOF",
    "cat > publish.txt <<'EOF'\ngit push gh-mine br\ngh pr create --fill\nEOF",
    "cat <<-EOF\n\tgit push\n\tEOF\necho done",
    "git stash push -m wip",
    "bash -c 'make -j8'",
    "gh api -XGET repos/x/y/pulls",
    "echo it's; gh pr view 1",
    "echo it's; git stash push",
    "echo it's; scdev issue 1 --json",
    "scdev --help 2>&1 | head -30",
    "scdev pr create --help",
    "scdev redmine users > /tmp/users.txt",
    "scdev redmine users ls >>users.txt 2>/dev/null",
    "scdev issue 8991 --json 2>&1 | jq .",
    "scdev issue 8991 > issue.txt",
    "scdev issues &>/dev/null",
    "scdev gh ghsa ls 2>&1|head",
    "gh pr view 1 >out 2>&1",
    "git log --oneline 2>/dev/null | head",
]


def decision(command):
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    p = subprocess.run([sys.executable, HOOK], input=payload, capture_output=True, text=True)
    if p.returncode != 0:
        return "error: rc=%d %s" % (p.returncode, p.stderr.strip())
    if not p.stdout.strip():
        return "allow"
    return json.loads(p.stdout)["hookSpecificOutput"]["permissionDecision"]


def main():
    failures = []
    for cmd in BLOCK:
        d = decision(cmd)
        if d != "deny":
            failures.append("expected deny, got %s: %r" % (d, cmd))
    for cmd in ALLOW:
        d = decision(cmd)
        if d != "allow":
            failures.append("expected allow, got %s: %r" % (d, cmd))
    for f in failures:
        print("FAIL", f)
    print("%d/%d passed" % (len(BLOCK) + len(ALLOW) - len(failures), len(BLOCK) + len(ALLOW)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
