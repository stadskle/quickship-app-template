---
description: Run the platform-conformance and security review on the current changes
---

Run the `quickship-reviewer` agent over the current diff before this app ships.

What to do:

1. Determine the scope of changes. If we're on a branch, run `git diff main...HEAD` to see the full branch diff. If on `main` with uncommitted changes, run `git status` and `git diff` (staged + unstaged). If neither finds anything, fall back to scanning the whole repo.
2. Invoke the `quickship-reviewer` subagent. Hand it a brief prompt naming the scope ("review the diff between main and HEAD" or "review the staged changes" or "review the whole tree") and let it produce its findings.
3. Show the agent's output to the user verbatim — do not summarise it away. The amateur traps are precisely the ones the user can't spot themselves.
4. If the agent reports any **block-merge** findings (Security, Platform, or stale Dependencies), state clearly that the change is not ready to deploy and offer to fix the flagged items. Do not proceed to `/deploy` until the review is clean or the user explicitly waives a finding (and the waiver should be recorded in the commit message).
5. If the review is clean, say so and confirm it's safe to proceed.

This command is intentionally a hard checkpoint. Running it after every non-trivial feature is the contract — the user is trusting you to flag mistakes they don't know how to spot.
