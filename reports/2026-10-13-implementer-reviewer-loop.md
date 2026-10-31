# Incident: implementer/reviewer handoff loop on a feature-workflow item

Date: 2026-10-13
Baton version: the herdr pane runner (`baton-handoff`, `baton-courier`), before the agent-team rewrite. Workflow `feature`.

## Summary
The conductor dispatched a small backlog item straight to the implementer. The implementer and reviewer then handed the item back and forth indefinitely. The reviewer's written verdict was PASS every time, but its handoff was recorded as `status: blocked, route: implementer`, so the implementer re-ran and reported done again.

## Timeline
- The conductor created the item, claimed it, wrote `conductor-run` and ran `baton-handoff --route implementer`, skipping researcher and principal because the change was small and well specified.
- The implementer committed the change and handed off done to the reviewer.
- The reviewer wrote a PASS report, but its handoff was `blocked` -> implementer.
- The implementer handed off done -> reviewer, the reviewer `blocked` again, and the same pair of handoffs repeated every 6-12 seconds.
- The user reported the loop and the conductor investigated.

## Root cause
`baton-handoff` runs `baton-item gate <item>` before a reviewer PASS counts. Here it failed: `baton-item verify <item>` printed "item <item> has no completed commit recorded".

The feature workflow requires `baton-item start <item>` before work and `baton-item complete <item> "<verification>"` after it. Items that went through the full researcher -> principal -> implementer path recorded both. This item skipped straight to the implementer: no start was recorded at dispatch, and the implementer never ran `complete`. The reviewer therefore could not record a PASS, the handoff degraded to `blocked`, and neither role had a rule telling it to stop and escalate.

## Contributing factors
- The conductor dispatched to the implementer without making sure the item's `baton-item start` was recorded. Skipping stages was allowed by the conductor prompt, but that path didn't cover the feature workflow's bookkeeping.
- The reviewer's blocked handoff didn't say why, and the implementer's "done" carried no new information, so no role broke the cycle.
- Report files were named after the topic rather than the item ref, so matching a report to its item relied on `conductor-run`.

## Resolution
- The implementer ran `baton-item start <item>` after the work was already committed, so the start was recorded at HEAD. `baton-item complete` then refused: "item <item> has no commit on the session branch yet". `baton-item` has no reset and no way to back-date a start, and the implementer correctly refused to edit its state files by hand.
- The conductor had the implementer add one small, genuine follow-up commit on top of the recorded start, run `baton-item complete`, and hand off to the reviewer once. The reviewer re-reviewed only the delta.
- Outcome: review PASS, `baton-item verify` succeeded and the item was closed. No work was lost, but the loop produced dozens of kata comments on the item before the conductor intervened.
- Afterwards the conductor ran `baton-item start <item>` itself at every dispatch that skipped researcher and principal, and no further loop occurred in the session.

## Lessons
1. A reviewer PASS that fails the gate should print the gate's reason and not be routed back as a plain blocked note; or the implementer prompt should say that a blocked note naming a missing `baton-item` record means fixing the record, not re-reporting.
2. Detect ping-pong: after N alternating handoffs on one item with no new commit, stop and route to the conductor.
3. When the conductor skips researcher and principal in the feature workflow, `baton-item start <item>` must still run at dispatch.
4. Name reports by item ref so `baton-item review --report` and `verify` can be matched mechanically.
5. A start recorded late can't be repaired, only worked around with a follow-up commit. Record `baton-item start` before any commit exists.
6. After a feature is finalized and merged, `baton-item start` refuses on a detached checkout and on a merged session branch, so small follow-up tasks have to run outside the pipeline with no review. Either allow a follow-up item in a finalized session, or start a new session for each.
7. A requirement left only as a kata comment never reached the principal's design and shipped missing; the user found it, not the review. Requirements must go in the item body, and the conductor should check the design against them before dispatching the implementer.
