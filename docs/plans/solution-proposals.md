# Solution proposals before the backlog

Every run starts by working out **what to build** and bringing a recommendation back to the user, before the conductor decomposes anything into a backlog.

Today the conductor decomposes the goal after only a lightweight scan, so the most consequential decision of a run - how the work is split - is made by the role that is forbidden to research or design, before anyone has investigated. For an issue (a bug, a vague problem) that means items are cut before the root cause is known.

## Behaviour

```
you ──issue──▶ conductor ──▶ researcher ──▶ (planner) ──▶ principal ──▶ reviewer ──▶ principal ──▶ conductor ──▶ you
                                                             proposal      critique     response      report + notify
you ──approve──▶ conductor ──▶ backlog from the proposal ──▶ existing pipeline
```

1. **Conductor** creates the goal issue (no items), marks the session as in its proposal phase, and dispatches the goal to researcher.
2. **Researcher** investigates as usual; for an issue, the Technical Brief must establish the root cause. It routes to planner or principal as today, never to implementer.
3. **Planner** (only when researcher found product questions) writes a Planning Brief as usual.
4. **Principal** writes a **Solution Proposal** instead of an Implementation Design: options, a recommendation, a proposed backlog, and the decisions the user should confirm. It routes to reviewer.
5. **Reviewer** critiques the proposal once (no code, no commit, no `baton-item`) and routes the critique back to principal.
6. **Principal** answers each critique point in the proposal (accepted and changed, or rejected with a reason) and routes to conductor.
7. **Conductor** reports the proposal to the user, sends a desktop notification, and stops.
8. **The user** approves, or asks for changes. Changes go back to principal as a new round (step 4 onward, critique included). Approval makes the conductor create the backlog items from the proposal's backlog, leave the proposal phase and dispatch them through the existing pipeline. There is no second backlog checkpoint: the user approved the backlog as part of the proposal.

This replaces the current "decompose, then stop for backlog review" checkpoint. It is the only way a run starts.

## Decisions

| # | Decision | Tradeoff |
|---|---|---|
| D1 | The proposal phase is mandatory, replacing the backlog-first checkpoint. | One start path to maintain and reason about. A trivial goal now pays for a research, design and critique pass before anything is built. |
| D2 | Proposal work is tracked on the **goal issue**: the conductor writes the goal ref as both lines of `conductor-run`, exactly as finalization already does. `$BATON_MARKER_DIR/proposal` (containing the goal ref) marks the phase. | Reuses existing handoff, kata-comment, staging and courier mechanics unchanged. The goal issue's comments become the proposal's record. |
| D3 | Rules that would loop or misroute are enforced in `baton-handoff`, not left to prompts: no handoff to implementer during the proposal phase, one critique per round, and no `baton-item gate` for the critique. | Lesson from the 08a0 incident: a rule that lives only in a prompt is eventually skipped. A refused handoff fails loudly in the agent's own shell, with the reason. |
| D4 | Rules apply only while the handoff's item **is** the goal ref named in `proposal`, and never once finalization has started (`final/phase`), which also works on the goal ref. | A `proposal` file the conductor forgets to remove cannot break ordinary items or finalization. |
| D5 | Notifications go through the marker dir: `baton-notify` queues text, `baton-courier` (outside every sandbox) shows it. | Works from codex's sandbox, which cannot reach herdr or the desktop. Only as reliable as the courier, which already has to be running for anything to move. |
| D6 | Proposal artifacts (Technical Brief, Planning Brief, proposal) go under `$BATON_MARKER_DIR/proposal-docs/`, the critique under `reports/`, and backlog item bodies point at them. The implementer reads them in place and never moves them. | No new commit path. They are not committed to the repository and are deleted by `baton remove`. An earlier draft staged them under `staging/<goal-ref>/`; the end-to-end run showed the implementer then treating the goal ref as its item (branch suffix, moving the files), which breaks a multi-item backlog. |

| D7 | The proposal phase counts as autonomous mode for questions: researcher, planner and principal decide a default and record it as `Q: … -> A: …` instead of asking. Principal collects these under Decisions to Confirm. | The user answers every question in one place, the conductor's report, instead of in role panes nobody watches. Found in the end-to-end run, where the planner stalled on an interactive question. |

## Enforcement in `baton-handoff`

While `$BATON_MARKER_DIR/proposal` exists and the handoff's item equals its goal ref:

| Situation | Behaviour |
|---|---|
| Any handoff whose target is implementer | Refused (exit 3): "the proposal phase builds nothing; route to reviewer (principal) or conductor". |
| Reviewer, `--status done` | Skips `baton-item gate` (there is no commit to gate). |
| Reviewer hands off | Records that this round's critique happened. |
| Any handoff whose target is reviewer after the critique happened | Refused (exit 3): "the proposal already had its critique this round; route to conductor". |
| Conductor hands off | Starts a new round (clears the critique record). |

## Solution Proposal format (principal)

- **Problem** - as understood, and for an issue the root cause, citing the Technical Brief.
- **Options** - two or three real alternatives, each with approach, tradeoffs, risk and rough size. When only one reasonable approach exists, say so and why; never invent a straw man.
- **Recommendation** - which option and why.
- **Proposed backlog** - ordered items: id, title, a 1-3 sentence description, dependencies, and whether it warrants the `checkpoint` label.
- **Decisions to confirm** - every `decided autonomously` answer from the briefs and the proposal, so the user can reverse any of them before work starts.
- **Critique response** - added after the reviewer's round: each point, accepted (and what changed) or rejected (and why).

## Steps

1. **`baton-handoff` proposal rules** with tests in `tests/handoff.sh` (D2-D4).
2. **Resume:** `nudge_conductor` tells a resumed conductor the session is in its proposal phase; test in `tests/nudge.sh`.
3. **Conductor prompt:** the proposal phase replaces first-invocation decomposition; telling a user message from a handoff; approval and revision handling; backlog creation from the approved proposal.
4. **Researcher, principal and reviewer prompts:** root cause and no implementer route; Solution Proposal mode; critique mode. Planner needs no change: it already routes to principal.
5. **Notifications:** `bin/baton-notify`, delivery in `baton-courier` with tests in `tests/courier.sh`, and the conductor notifying on every stop.
6. **README:** the new start of a run, the proposal phase in "How it works", and `baton-notify`.

Each step keeps the full test suite passing. Steps 3 and 4 are prompt changes, which no test exercises; they need one real session to verify end to end.

## Out of scope

- The 08a0 gates (refusing an implementer `done` without a completed commit, refusing a reviewer bounce without a recorded CHANGES verdict, a ping-pong breaker, and `baton-item start --at`). These are independent of this plan.
- Codex panes losing their typed persona when the courier sends `/clear` on an item switch. The proposal phase adds one item switch per run, so this should be checked first if codex is assigned to a role.
