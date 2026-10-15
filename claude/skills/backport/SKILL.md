---
name: backport
description: Use when asked to backport Suricata commits, a PR or a ticket from main to 8.0.x (main-8.0.x), or to prepare the Suricata-Verify side of such a backport.
argument-hint: <PR number | commit SHAs | ticket id>
---

# Backport to 8.0.x

Input: $ARGUMENTS

**NEVER change detection, runtime or configuration behavior on 8.0.x unless the user explicitly
asked.** When a backport cannot be clean, give the user a full explanation and the options before
finishing it.

`$R` below is the OISF remote of this checkout (`git remote -v`, often `github`). Run
`git fetch $R` first.

1. **Collect the `main` commits**, in their original order: from a PR
   (`gh pr view <n> -R OISF/suricata --json commits`), SHAs, or a ticket
   (`git log $R/main -E -i --grep='Ticket:?.*[#/ ]<id>([^0-9]|$)'`; the format varies). Given
   SHAs, also list the other commits of their tickets: a named commit may depend on them. Each
   must be in `$R/main` (`git merge-base --is-ancestor <sha> $R/main`).
2. **Find the backport tickets.** Each original ticket has an 8.0.x child ticket, titled
   "... (8.0.x backport)": `scdev issue <orig> --json | jq '.children'`. If one is missing, ask
   the user.
3. **Branch** from `$R/main-8.0.x`: `backport-8.0.x/<type>/<backport tickets>-<slug>-v1`, e.g.
   `backport-8.0.x/bug/8968-8970-flow-scope-backports-v1`.
4. **Cherry-pick** with `git cherry-pick -x <sha>...`. In each message, replace `Ticket:` with the
   backport ticket, and keep `(cherry picked from commit ...)` as the last line.
5. **Conflicts and missing pieces:** adapt minimally. Inline `main`-only helpers instead of
   backporting unrelated commits, and keep 8.0.x APIs, config and output. If adapting would change
   behavior or pull in other commits, stop and present the options. Explain each adaptation in the
   commit body.
6. **Rebuild** (autogen to make after the branch switch), then run the change's unit and SV tests.
7. **SV tests** that came with the `main` commits go on an SV branch named like the Suricata one,
   from SV's upstream `master`. Use the writing-sv-tests skill: lower the tests' `min-version` to
   the 8.0.x release and split the checks that differ between 8 and 9.
8. **Check** with the pre-push-checks skill (it also verifies the cherry-pick references), then
   the local CI jobs that run on 8.0.x and are relevant to the change (running-local-ci skill).
9. **Review:** if any commit was adapted, dispatch a NEW `suricata-reviewer` with base
   `$R/main-8.0.x`, the backport tickets and "same behavior as the `main` commits, nothing else
   changes on 8.0.x". Fix confirmed findings and re-review with a new instance.
10. **Report:** both branches, the original → backport commit map, every adaptation and why, test
   results with their commands, and the exact commands for the user to push. Never push.
