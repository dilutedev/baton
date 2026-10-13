# Session worktrees and one PR per feature

Implement this as **one session worktree, one session branch, reviewed commits per backlog item, and one feature PR into the selected base branch**.

The feature workflow's key invariant is: **the next item cannot begin implementation until the previous item is verified, committed on the session branch, and passed by reviewer.** The worktree lifecycle ships independently before this workflow is enabled.

## Decision: one PR per session

A backlog task is not automatically a GitHub review boundary. Baton already reviews each item, so creating, running CI for, and merging a separate PR per task adds process and recovery work without necessarily creating independently shippable changes.

Default to one draft feature PR once the session has code, update it as reviewed items finish, and require a final review of the combined feature before marking it ready. If the resulting PR is too large, split the goal into smaller sessions that can ship independently.

Item PRs may be useful when separate human approvals or GitHub checks are explicitly required for each item, but they are outside this implementation. This decision supersedes the earlier item-PR integration design: do not implement internal PR merges, a courier integration helper, squash strategy selection, or a CI/merge gate between items.

## Delivery boundaries

Deliver this in three stages:

| Deliverable | Scope | Success criterion |
|---|---|---|
| A: Sandbox feasibility spike | Disposable worktree and real agent handoff across the worktree boundary | Sandboxed roles can persist reports and handoffs, Kata resolves the correct project, and the outside courier delivers them |
| B: Session worktree lifecycle | Base selection, metadata, creation, stop/resume/remove, discovery, status, and launch configuration | Two sessions operate in separate checkouts and survive stop/resume without changing existing item branch or PR behavior |
| C: One PR per session | Shared session branch, reviewed item commits, durable review evidence, one draft feature PR, and final feature review | Items advance after verified commits pass review and the session produces one reviewed feature PR into its saved base |

Complete A before committing to the filesystem arrangement. Ship B as its own implementation PR, with its own tests and documentation. Ship C separately after B is verified. B must not enable the new feature workflow merely because a session has a worktree. These implementation PRs deliver changes to Baton itself; they do not imply a runtime PR per backlog item.

Persist an explicit workflow version: absent means legacy behavior, `worktree-v1` means isolated lifecycle with current item semantics, and `feature-v1` means one branch and PR per session. New sessions use the version supported by their release. Never silently upgrade existing sessions when Baton is updated or resumed. `integration-v1` was a proposed name in the superseded plan, not a workflow to implement.

## 1. Define the behavior

```bash
baton start --base main [DIR]
baton start --base origin/develop [DIR]
baton start [DIR]
baton stop [REF] [DIR]
baton resume [REF] [DIR]
baton remove [REF] [DIR]
```

| Action | Behavior |
|---|---|
| Start | Create a new session branch, Git worktree, and dedicated Herdr workspace |
| Stop | Close that workspace, retaining checkout, branches, and Baton state |
| Resume | Reopen the existing worktree and reconstruct the pipeline |
| Remove | Safely delete the worktree and session state; retain Git branches |
| Item completion | Verify and commit on the session branch, pass review, then close the item |
| Feature completion | Review the combined feature and mark the existing draft PR ready against the selected base |

Recommended policies for this plan:

- In `feature-v1`, implementer commits each item directly to the session branch. No item branch or item PR is created.
- Baton never automatically merges the final feature PR into the selected base.
- Research and planning retain their existing overlap; implementation and review remain serialized.
- Existing sessions retain their current behavior rather than being silently migrated.
- Worktree lifecycle supports local repositories; `feature-v1` initially requires an authenticated GitHub remote and the GitHub CLI to publish its single PR.
- Reviewer reports stay outside the PR branch, with durable approval evidence in Kata.
- No new dependencies.

These are proposed implementation policies; no merges or other external changes are authorized merely by generating this plan.

## Deliverable A: prove sandbox and handoff feasibility

Before implementing lifecycle changes, use a disposable repository and worktree to test the actual configured agent tools under their normal sandbox policies.

1. Put the marker directory under the original repository and launch the agent from the separate worktree.
2. Grant access to that specific marker directory using verified, supported tool launch options.
3. Have the sandboxed agent write a report and invoke `baton-handoff` against a disposable Kata project.
4. Verify queue writes, Kata project resolution, and actual delivery by the courier running outside the agent sandbox.
5. Exercise access after a fresh launch to represent resume, and check the supported Claude accounts and other configured tools.

Do not bypass sandboxing to make the spike pass. Record the exact launch arguments and observed results. If the arrangement fails, resolve marker storage and handoff transport before proceeding to B; a flag-only or stub-only test is insufficient.

The spike does not merge PRs or change the product workflow. Its output is a reproducible feasibility result and the minimum required launch changes.

### Spike results

Scripts: `tests/spike/sandbox-worktree.sh` (non-interactive Codex), `tests/spike/sandbox-worktree-pane.sh codex|claude|omp` (real herdr pane), and `tests/spike/sandbox-worktree-courier.sh` (courier delivery and relaunch). Each uses a throwaway repository, worktree, and `KATA_HOME`, and closes only the herdr workspace it created.

Launch used: pane cwd is the worktree, with `BATON_ROOT` set to the worktree and `BATON_MARKER_DIR` pointing at the marker directory under the original repository. No `--add-dir` or other extra access flags.

| Tool | Commit | Branch | Report in marker dir | Kata comment from worktree | Handoff queued |
|---|---|---|---|---|---|
| Codex, `workspace-write`, no approvals (`codex exec`) | fail | pass | pass | fail | fail |
| Codex, plain checkout, no approvals (control) | fail | pass | pass | fail | fail |
| Codex, interactive pane, approvals granted | pass | pass | pass | pass | pass |
| Claude, interactive pane | pass | pass | pass | pass | pass |
| omp, interactive pane (herdr integration installed) | pass | pass | pass | pass | pass |

- The Codex failures are identical in a plain checkout, so they come from Codex's sandbox rather than the worktree: it blocks writes to `.git` (`index.lock`) and connections to kata's unix socket (`baton-handoff` exits 7). Allowing the common git directory with `--add-dir` did not help. Codex roles depend on interactive approvals with or without a worktree, and each distinct command prefix is approved separately.
- Marker-directory writes outside the worktree needed no extra access for either tool.
- Kata resolved the project from the worktree through the committed `.kata.toml`.
- Courier delivery: with the agent mapped to the conductor role, `baton-courier --once` typed the queued payload into a Claude pane launched in the worktree, emptied the queue, recorded the delivered item, and the pane acted on it.
- Relaunch: after closing the workspace, a fresh Claude launched in the same worktree committed on the same branch history, handed off, and received a courier delivery. This approximates resume; it does not exercise `herdr worktree open`, which belongs to deliverable B.
- Claude shows a trust dialog for each new worktree path. The existing `prepare_profile` trust preparation must be applied to the worktree path before launch.

- omp ran all four commands without approvals or trust prompts. Its courier delivery and relaunch were not run; they depend on the herdr omp integration being installed so herdr can see turn state.

Not covered: `claude2` (same CLI under a different config directory, expected to match Claude), and courier delivery and relaunch for omp. Test them before supporting them for managed sessions.

## 2. Resolve and persist the base branch

Implement in `bin/baton`, starting at `cmd_start`.

Add `--base` to `start`, preserving `--think`, `--yes`, and directory handling.

Base resolution should be explicit:

- `--base main` uses the local branch's committed tip.
- `--base origin/main` refreshes that remote branch before creating the session.
- When omitted, use the repository's detected remote default branch.
- If the default cannot be determined reliably, fail with instructions to specify `--base`.
- Reject tags, arbitrary commit SHAs, and missing branches for this workflow: the final PR needs a branch target.

Record both the resolved starting commit and, when a remote exists, the final PR's remote/target branch. For example, `origin/main` means "start from this remote-tracking ref" and "eventually target `main` in that remote repository." Local repositories can start with an explicit local base in deliverable B.

Do not silently fall back to the caller's current feature branch. Do not change or stash the caller's uncommitted work.

For multiple remotes, resolve from the explicitly selected remote-tracking base where possible. If a local base leaves the target repository ambiguous, require an explicit remote selection rather than guessing.

## 3. Add durable session metadata

Keep the existing marker-file conventions under the original repository:

```text
.baton/s/<session-id>/
    worktree
    workflow_version
    session_branch
    base_branch
    base_commit
    remote
    workspace_id
    tab_id
    ...
```

Use a stable branch name such as `baton/<session-id>` because the feature goal is currently supplied after startup. The conductor can continue assigning the human-readable goal slug later.

In deliverable C, persist each item's starting commit, completed commit, reviewed commit, verdict, and review path. Record PR identity once at session level. These records support recovery and enforce the item review gate; Kata remains the source of truth for backlog status. Do not add per-item branch, PR, or merge-result metadata.

Separate three paths throughout the implementation:

- Repository root: session discovery and project configuration.
- Session worktree: source code and Git operations.
- Marker directory: queues, reports, and lifecycle state.

Commands invoked from inside a managed worktree must still find the original session registry. Normalize repository identity using Git's common directory and registered worktrees, rather than treating the managed checkout as a new project.

## 4. Create the Herdr worktree and launch roles

Refactor `spawn_pipeline_panes` in `bin/baton` to separate workspace creation from role-pane creation.

Startup sequence:

1. Validate dependencies, configuration, Git repository, base, and required prompts.
2. Allocate the session ID and persist its intended branch/path.
3. Create the worktree with explicit branch and resolved base commit.
4. Persist the returned workspace and worktree information immediately.
5. Create the pipeline tab inside that dedicated workspace.
6. Launch all six roles with the existing layout and environment handling.
7. Start the courier and focus the conductor.

Herdr's `worktree create` was probed live and is not used. It also registers the source repository as an extra workspace in the user's sidebar, closing that group needs `--group`, its CLI does not accept Baton's `--env` flags, and it would leave a bootstrap tab to clean up. Instead create the checkout with `git worktree add -b baton/<session-id> <path> <base-commit>` and launch the pipeline with `herdr workspace create --cwd <worktree> --env ...`, the same call deliverable A exercised. Session worktrees live under `~/.baton-worktrees/` (override with `BATON_WORKTREE_DIR`), outside the repository so test runners and editors never scan them. See the [Herdr CLI reference](https://herdr.dev/docs/cli-reference/).

Always create a dedicated workspace, including when Baton starts inside another Herdr workspace.

Pass:

- `BATON_ROOT`: session worktree.
- `BATON_MARKER_DIR`: original repository's session directory.
- Existing role and run settings.

Continue resolving project configuration from the original repository. Apply Claude trust preparation to the worktree.

The marker directory outside the worktree needs no extra launch flags for Claude or interactive Codex; see the deliverable A results. Verify it again with actual handoff behavior for any other tool.

## 5. Make startup failures recoverable

Persist resource identities as they are created, rather than only after all agents launch.

If pane or agent startup fails:

- Report the failed role or operation.
- Preserve the checkout and session metadata.
- Close only resources definitely owned by that session when cleanup is appropriate.
- Leave enough state for `resume` or `remove`.
- Never delete a checkout merely because an agent failed to initialize.

Validate failures that can be detected before worktree creation first.

Ensure `.baton/` remains locally ignored without introducing unrelated tracked changes in the caller's checkout.

## 6. Commit items on the session branch and maintain one draft PR

This section belongs to deliverable C and applies only to `feature-v1`. Deliverable B retains the current trunk/blocker branching rules and current PR targets, inside the isolated checkout.

Change the version-control instructions in `prompts/implementer.prompt.md`. `feature-v1` requires an authenticated GitHub remote, a resolved target repository, and the GitHub CLI; fail before creating a session if these prerequisites cannot be met. Existing legacy and `worktree-v1` sessions retain their current local-only behavior. Defer other hosting providers and a local-only variant of the new feature workflow.

For each item:

1. Confirm the previous item passed review and the checkout is on the recorded session branch, never trunk or another session's branch.
2. Record the current session commit as this item's starting point.
3. Bring in staged artifacts, implement, and run the relevant verification.
4. Commit the item on the session branch and record the completed commit and verification evidence. A task may need additional fix commits after review; do not rewrite earlier reviewed history to force one commit per item.
5. Push the session branch. Once the session has code, create or reuse its one draft PR explicitly targeting the recorded base branch.
6. Hand off the item report and exact commit range to reviewer.
7. After PASS, allow the next item's implementation. Its commits extend the same branch and automatically update the same PR when pushed.

Look up and reconcile an existing PR by the recorded repository, head branch, and base before creating one, including after an interrupted create request. Persist its identity once at session level. Never open a new PR merely because a new item started. If the PR was externally closed or merged before the session finished, stop and report the changed state rather than silently opening a replacement.

Remove item branch creation, trunk/blocker branching, per-item PR targeting, internal merge helpers, and per-item merge queues from the new workflow. Completed predecessors are already commits on the session branch.

Keep upstream document staging: several roles still share one checkout, so their writes need the existing protection. Do not force-update checked-out branches, reset user changes, force-push, or automatically delete branches. A divergent remote session branch is a visible blocker requiring reconciliation.

Baton already serializes implementation through reviewer PASS. Retain that boundary without adding a mandatory GitHub CI or merge wait between items. Run relevant local verification for each item; inspect accumulated CI results during finalization. If a failure is discovered earlier, route the necessary fix to implementer. Parallel implementation and item-specific worktrees remain out of scope.

## 7. Enforce verified commit → review → item completion

Keep the existing courier focused on delivering handoffs. It does not gain GitHub merging, CI polling, or detached integration jobs.

Use this sequence:

```text
Implement and verify → Commit on session branch → Review
                                                  ↘ Changes required → Fix and commit
Reviewer PASS for recorded commit → Release next build → Conductor closes item
```

Currently `bin/baton-handoff` releases `build.item` on reviewer PASS. Preserve this structure, but for `feature-v1` require persisted evidence that the reviewed commit matches the item's completed commit, is the current session branch tip, and the checkout has no uncommitted source changes. Missing evidence or a changed tip must not release the build gate. Test behavior rather than relying only on prompt instructions.

Reviewer inspects the recorded item commit range and important interactions with earlier session changes. On CHANGES REQUIRED, implementer adds fixes on the same session branch and records the new completed commit for renewed review. Previously passed item records remain historical evidence; later commits do not invalidate every earlier item, but do require final review of the combined feature.

For `feature-v1`, reviewer persists reports under `$BATON_MARKER_DIR/reports/` and does not commit or push a review artifact. Record the verdict, item starting and reviewed commits, verification summary, findings, and report path in Kata as well as the local report. Local report deletion during `remove` must not erase the approval evidence. Preserve older sessions' review-document conventions.

Persist approval and enqueue the conductor notification alongside the gate update under the existing state lock, without running external calls while holding the lock. Recover interrupted notifications without duplicating item completion. The conductor closes the Kata item only after checking its recorded PASS evidence. Retain the existing per-item queue and review-fix routing.

Push or PR creation failures are publication blockers, not reasons to discard local commits. Resume reconciles the local and remote branch and PR identity before retrying publication. No automatic merge is part of item or feature completion.

## 8. Review the whole feature and mark its PR ready

This section belongs to deliverable C. Update conductor completion in `prompts/conductor.prompt.md` for `feature-v1` so exhausting the backlog enters finalization.

Finalization:

1. Verify every implementation item has a recorded reviewed commit on the session history and is closed in Kata.
2. With no active repository writer, confirm the checkout is clean and on the session branch. Check remote state without resetting or rewriting local history.
3. Have implementer run relevant whole-feature verification and push any outstanding session commits.
4. Reuse the session's draft feature PR and verify that its head and target match the recorded session and base branches.
5. Have reviewer inspect the complete feature diff against the selected target, combined acceptance criteria, and current CI results. Item PASSes alone do not establish final readiness.
6. After final PASS and required checks succeed, mark that same PR ready for user review/merge.
7. On failure, create or reopen a fix item, add reviewed fix commits to the same branch, and repeat final review on the updated head. Do not create an item PR.

Reports remain in the marker directory, durable evidence stays in Kata, and readiness is tied to the reviewed feature PR head and target state. Pending checks leave finalization waiting; failing checks leave it blocked. A changed head requires renewed final review. Baton never merges the PR. Leave its eventual merge strategy to repository policy and the user.

Represent finalization explicitly in durable session state. Route it through the existing queues using the goal reference, with a phase distinguishing it from ordinary item work.

Keep the goal open until final review and required checks pass. Report "ready to merge," rather than "shipped," while the feature PR remains unmerged.

If the target branch advances, check whether the combined review or verification needs repeating and report conflicts or required updates. Do not automatically rebase or rewrite the session's history.

## 9. Implement stop, resume, and remove

### Stop

Close only the session workspace. Preserve all checkout contents and pipeline state. Distinguish an already-closed workspace from a Herdr server error.

### Resume

Reopen the recorded checkout through `herdr worktree open`, save its current workspace/tab IDs, and restart roles.

Preserve the current branch and uncommitted work. Do not switch branches during resume. For `feature-v1`, a branch different from the recorded session branch is a visible blocker, not permission to discard work.

For `feature-v1`, reconcile durable progress before dispatching:

- Which item commit was completed and which commit was reviewed?
- Was PASS recorded but its Kata item left open?
- Are local session commits published, and does the recorded draft PR already exist?
- Has the PR been externally closed or merged?
- Was finalization already underway?

If the checkout is missing, report the missing path and retained branch. Do not silently create a replacement checkout that loses local context.

### Remove

Stop the session, then verify the exact registered worktree and repository identity before removal.

For the initial implementation:

- Refuse dirty checkout removal.
- For `feature-v1`, verify committed work is published to the recorded remote before deleting the checkout; retain metadata if publication cannot be verified. The session PR may remain open because removing a local checkout does not close or merge it.
- Retain branches and print their names for recovery.
- Preserve metadata if removal fails.
- Delete session metadata only after confirming checkout removal.
- Never remove the primary checkout or follow a substituted symlink.

A stopped workspace may need reopening before calling Herdr's workspace-addressed removal command; handle that without launching agents. Herdr keeps workspace closure and checkout deletion separate. See the [Herdr CLI reference](https://herdr.dev/docs/cli-reference/).

## 10. Preserve compatibility and expose progress

Dispatch lifecycle and handoff behavior using the explicit workflow version. Sessions without it retain their existing lifecycle and handoff rules; `worktree-v1` uses the isolated lifecycle with existing item semantics; `feature-v1` uses one session branch and PR. Do not infer migration from the existing `worktree` pointer alone: that pointer already supports manually created worktrees. Test all three paths on update and resume.

Update `status` to show:

- Worktree path and session branch.
- Workflow version.
- Selected base.
- Running/stopped state.
- Current build item.
- Item verification/review state and any publication blocker.
- Session draft PR and finalization/CI state.

In deliverable B, update all six prompts so managed worktree ownership belongs to Baton, while retaining manual worktree behavior for legacy sessions. Prevent implementer from creating another session worktree in either new workflow version. In deliverable C, make shared-branch commits, single-PR publication, review evidence, item gating, and finalization conditional on `feature-v1`.

Update README usage, lifecycle, one-PR-per-session behavior, completion terminology, workflow compatibility, GitHub publication prerequisites, and the retained review serialization in their respective deliverables. Explain that oversized features should become smaller independently shippable sessions, and separate item PRs are outside this implementation. Document the dependency/configuration caveat: worktrees do not automatically provide ignored `.env` files, installed dependencies, isolated databases, or unique ports.

## 11. Verify with behavioral tests

Extend the existing Bash tests and add focused lifecycle and feature-workflow scripts. Use real temporary Git repositories for branch and checkout behavior; stub Herdr, GitHub, and Kata at their external boundaries.

Required cases:

| Area | Acceptance cases |
|---|---|
| Sandbox spike | Real sandboxed report writes, queue writes, Kata resolution, courier delivery, and fresh-launch access across the worktree boundary |
| Base | Explicit local/remote branch, detected default, invalid or ambiguous target |
| Isolation | Two sessions have different branches/checkouts; caller's edits remain intact |
| Launch | Every role receives correct cwd, marker path, settings, and environment |
| Failure | Partial startup leaves recoverable metadata |
| Item commits | Multiple items and review fixes extend one session branch; no per-item branch, PR, or merge is created |
| Review gate | Only PASS matching the recorded completed commit and clean session tip releases the next build; changed head and missing evidence retain it |
| Courier | Existing delivery and review-fix routing continue; no CI/merge wait or new integration job blocks other handoffs |
| Review evidence | Review leaves the PR head unchanged; verdict and reviewed commits remain in Kata after local reports are removed |
| Git updates | Session history grows without resets or force-pushes; divergence, unexpected branches, and dirty state are preserved |
| Recovery | Shutdown after commit, push, PR creation, or PASS does not duplicate a PR or lose item completion |
| Finalization | Exactly one draft PR targets the saved base; full feature review and required CI precede readiness; no automatic merge |
| Lifecycle | Stop preserves files; resume reuses checkout; remove retains branches |
| Compatibility | Legacy, `worktree-v1`, and `feature-v1` retain their recorded behavior on update and resume |
| Prerequisites | Local lifecycle works with an explicit base; feature publication rejects missing GitHub credentials or tooling |
| Safety | Missing resources, symlinks, dirty checkout, and server errors preserve recoverable state |

For B, run existing tests, shell syntax checks, lifecycle tests, and a disposable live Herdr smoke test before shipping its PR. For C, run those checks plus feature-workflow tests and a disposable GitHub end-to-end test that creates one draft PR, updates it across multiple reviewed items, and marks it ready after final verification. No PR merge is required. The live sandbox spike in A is a prerequisite, not a replacement for lifecycle and feature-workflow verification.

## 12. Implement in this order

1. A: Run and document the disposable sandbox feasibility spike; resolve any marker access or Kata binding failures.
2. B: Implement base resolution, lifecycle metadata, and the `worktree-v1` discriminator.
3. B: Implement Herdr worktree startup, role launch, stop/resume/remove, and discovery.
4. B: Complete status, compatible prompts, lifecycle documentation, and verification; ship this as its own PR with current item semantics intact.
5. C: Implement `feature-v1` prerequisites, item commits on the session branch, and publication through one reusable draft feature PR.
6. C: Implement approval evidence outside the PR branch, durable recovery, and the verified-commit review gate using existing handoff/courier delivery.
7. C: Implement whole-feature review, required CI verification, and readiness for the same PR.
8. C: Complete workflow status, prompts, documentation, and full verification; ship separately without upgrading existing sessions.

The work is complete when two concurrent sessions can independently build features, each item produces verified commits reviewed on its session branch, interruption preserves progress, and each session produces exactly one reviewed feature PR into its saved base—without modifying the caller's working checkout or automatically merging any PR.
