---
name: suricata-change-workflow
description: Use when the user's prompt contains "ultrathink", or asks for the full multi-agent workflow, for a Suricata bug fix or feature.
---

# Suricata change workflow

Every subagent, implementer and reviewer alike, runs on the most capable model available: pass
`model: "fable"`, else `"opus"`.

1. **Clarify** with superpowers:brainstorming until the assignment is unambiguous. Read the ticket
   (`scdev issue <id>`).
2. **Plan** with superpowers:writing-plans. The plan names the tests, the docs (userguide, upgrade
   guide), the EVE schema and the modes, runmodes, capture methods, extensions and plugins the
   change touches, with the edge cases for each. It names every piece of state the change caches
   or moves, the scope that owns it and every exit of that scope that must clear it (firewall
   early exits included), and every reader outside the scope.
3. **Tests first:** reproduce the behavior with a test that fails now, usually SV (writing-sv-tests
   skill), on an SV branch named like the Suricata branch. In this workflow tests count as
   requested, but they must still be unique.
4. **Implement** the plan (superpowers:subagent-driven-development, or inline for small changes).
   The fix and its tests share a commit; docs ship with the code.
5. **Check** with the pre-push-checks skill, then run the local CI jobs relevant to the change
   (running-local-ci skill). For a change to detection, flow or app-layer state also run the
   firewall SV suite and an adversarial reproducer under valgrind or ASAN (CLAUDE.md,
   "Correctness rules"), on head and base. Fix every FAIL in the commit it belongs to; a bug the
   base already has gets its own commit and ticket.
6. **Review:** dispatch a NEW `suricata-reviewer` agent with the base ref, the ticket, the
   intended behavior and the invariants from the plan (cached state and its scope, locking).
   Verify its findings (superpowers:receiving-code-review), fix the confirmed
   ones, then repeat from step 5 with another new reviewer. Stop when a fresh reviewer reports no
   blocker or major finding.
7. **Report:** branch and commits; test results with their commands; per review round, what it
   found and how each finding was resolved; open design questions; and the exact commands for the
   user to publish. Never push.

## Red flags

- Reusing a reviewer, or treating your own check as the review: every round gets a fresh
  `suricata-reviewer`.
- Stopping while the latest reviewer still has blocker or major findings, or because "the rest
  are minor" before checking that they are.
- Skipping step 5 because it built locally: CI builds every commit and checks formatting.
- Taking a green targeted test as evidence for paths it never runs: firewall early exits,
  packet/IP-only/frame post-match, autofp, flow recycle. Those need a reproducer built for them.
- Folding a pre-existing bug found on the way into the fix's commit without saying so.
