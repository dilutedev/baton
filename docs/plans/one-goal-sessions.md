# One goal per session, one PR per goal

Decided with the owner on 2026-11-04. Replaces the `feature` and `worktree` workflows.

## Why

- A PR must hold exactly one goal. Today the PR belongs to the *session* (`baton-item` records one branch and one PR per session), so a second goal given to a running session lands in the first goal's PR. The `worktree` workflow does the opposite and spreads one goal over one PR per item.
- A PR must be a series of meaningful commits. Today the implementer pushes right after committing and before review, so every review round has to become another commit on top ("Review fixes are new commits on top"), and nobody plans or judges the commit series.
- A human must understand what the agents did before it leaves their machine. Today nothing stops between the proposal approval and "ready to merge" except `checkpoint` items.

## The model

Every session:

1. **Has its own worktree and branch.** `baton start` always creates `baton/<id>` in a new worktree from the base. There is no `--workflow`/`-w` any more; passing it is an error that says every session now works this way. With a GitHub remote (and `gh`), the goal ends in one pull request; without one, it ends with the branch ready locally.
2. **Works exactly one goal.** Once the session has a goal (`slug` exists), the conductor refuses a new goal and tells the user to run `baton start --goal "<goal>"`, which gives it its own worktree, branch and PR. Follow-up changes to the *same* goal are fine.
3. **Plans its commits.** The principal's Implementation Design has a **Commits** section: an ordered list, each commit one purpose, building on its own (fast checks per commit; the full test suite at the tip), with a subject and the *why* for its body.
4. **Builds item by item on the one branch**, as the feature workflow does today: `baton-item start`, commits to the plan, check-ins, `baton-item complete`, review, `baton-item gate`, close. **No push per item.**
5. **Folds review fixes into the commit they belong to** while the commits are unpushed: `git commit --fixup=<sha>` then `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash <item start commit>`, then `baton-item complete` again. The reviewer re-reviews with `git range-diff`. A "fix review" / "address feedback" / "wip" commit never lands.
6. **The reviewer judges the commit series too.** Blocking findings, like a bug: a commit with two purposes, a commit that doesn't build on its own, a message that doesn't say why, a fixup/wip/review-fix commit, an unrelated change.
7. **Finalizes once:** `baton-item final-start`, whole-goal verification by the implementer (no push), then the final reviewer reviews `base..HEAD` - code, acceptance criteria, rule files, and the commit series read top to bottom - and writes the **owner's guide** (below). `final-review PASS` no longer needs anything pushed.
8. **Stops for the owner, always** (also with `--think`). The conductor sends the guide's path and its bottom line, runs `baton-notify`, and waits:
   - **"ok"**: the conductor runs `baton-item approve`, comments `approved by owner: <sha>` on the goal issue, and has the implementer publish (push + draft PR). Then `baton-item ready --wait` as today. Without a remote: close the goal, report the branch.
   - **a question**: answered from the guide and reports; nothing changes.
   - **"change X"**: back to the implementer. Before the first push, the fix may be folded into any commit of the goal (`--autosquash <base_commit>`); the final review runs again on the new range, and the owner gets an updated guide and stops again.
9. **Never rewrites pushed history.** After the push, a fix (failing CI, PR feedback) is a new commit with a meaningful message ("Handle expired cookies in the refresh path"), re-reviewed by the final reviewer and shown to the owner again (approval is per commit: `publish` only pushes an approved tip).

`checkpoint` items still stop the run after they close. The proposal still waits for approval.

## Owner's guide

`$BATON_MARKER_DIR/docs/goal/owner-guide.md`, written by the final reviewer, one page:

```
Bottom line          what the PR does for the goal, 2-3 lines
Commits              in reading order: <sha> <subject> - what to look at in it and why
Look here            3-5 path:line spots, riskiest first, each with why it matters
How it was verified  commands and results; review findings and how they were resolved
Not verified         what the agents could not check (prod data, external services, UI by eye) - where the owner's judgement is needed
Deviations           from the approved proposal or designs, with the reason
Rule files           which repository rule files applied; confirmed followed
Try it               1-3 commands to see it working
```

The PR body is built from it (bottom line, commits, how verified, not verified), without marker-dir paths, kata refs or role names (team-protocol's commit and PR rules).

## `baton-item` changes

- Drop the `workflow = feature` guard; every session uses it. Sessions without a GitHub remote get every command except `publish` and `ready`, which say there is nowhere to publish.
- `final-review PASS`: requires the clean session tip, nothing about pushes or the PR.
- New `approve`: requires finalization started and a final PASS on the current tip; records `final/approved_commit`; logs it. The conductor runs it only after the owner's "ok".
- `publish`: refuses unless `approved_commit` is the current tip. Also refuses if the published tip (when there is one) isn't an ancestor of HEAD (history rewritten after a push).
- `complete`: also refuses if the published tip isn't an ancestor of HEAD.
- `ready`: requires `approved_commit` = tip = PR head, plus the existing checks.
- `status`: shows the approval.
- The header comment and usage reflect all of this.

## Session migration

Existing sessions keep working on resume: a `feature` session follows the new rules from its current state (anything already pushed stays as it is). A `worktree`-workflow session's per-item branches are left alone; it continues on its session branch. A marker dir with no `worktree` (pre-worktree sessions) is refused on resume with a message to `baton remove` it. The `workflow` marker file is no longer written or read for decisions.

## Commits for this change

1. `baton-item`: hold publication until the owner approves the final review (approve, publish/ready/final-review/complete changes, no workflow guard) - tests.
2. Every session works one goal on its own branch: remove `--workflow`, the worktree workflow and its per-item branches/PRs from `bin/baton`, prompts, README and tests; one goal per session in the conductor prompt.
3. Plan each item's commits and fold review fixes into them: principal, implementer and reviewer prompts.
4. Stop for the owner with a one-page guide before anything is pushed: final reviewer's guide, conductor's owner stop, PR body from the guide, README.
