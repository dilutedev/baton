# baton

Talk to one Claude Code agent, the **conductor**, and let it run a team of
engineers for you.

You tell the conductor what you want built or which issue you want fixed. It
behaves like a principal engineer: it works out the real problem, decides how
the team should approach it, picks the model for every piece of work (Haiku,
Sonnet or Opus), and stays in conversation with each teammate while it works,
questioning findings, correcting code that doesn't fit the codebase, and
pulling in the principal when it needs a second senior opinion. Then it brings
you the bottom line: the recommendation, your real options, and what needs
your decision, so you don't have to review everything yourself.

```
            ┌───────────── you ─────────────┐
            │  goal · approval · decisions   │
            ▼                                │ bottom line
        conductor (opus) ────────────────────┘
   chooses a model per task, stays in the conversation, corrects, decides
     │          │            │              │               │
 researcher   planner    principal     implementer      reviewer
 haiku/sonnet  sonnet    opus/sonnet   sonnet (opus)  sonnet/opus
 root cause   scope      proposal,     builds, checks   independent
              questions  design,       in at plan,      verdict
                         advice        progress, commit
```

Every goal starts with a [proposal phase](#the-proposal-phase): the team
investigates and the conductor brings you a recommendation and a proposed
backlog. Nothing is built until you approve it. After that the conductor
delivers the backlog on its own, item by item, as reviewed commits on one
draft pull request.

Baton is built on Claude Code's [agent teams](https://code.claude.com/docs/en/agent-teams):
the conductor is the team lead, and each role is a teammate it spawns from an
agent definition baton generates. Baton itself provides the roles' prompts, the
isolated session worktree, the kata backlog, and the commit and PR checks
(`baton-item`) that keep the work honest.

- [Quick start](#quick-start)
- [How a session works](#how-a-session-works)
- [Requirements](#requirements) · [Install](#install)
- [Usage](#usage)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Environment variables](#environment-variables) · [Tests](#tests)

## Quick start

```sh
git clone <this repo> ~/.baton
~/.baton/install.sh          # then open a new shell

cd ~/code/my-project
kata init                    # once per project
tmux                         # optional: gives every teammate its own pane
baton start                  # opens the conductor in this terminal
```

Tell the conductor your goal, or describe an issue (`baton start --goal "..."`
does the same from the command line). It comes back with a proposal and a
desktop notification. Reply to approve it or ask for changes. Once you
approve, it builds the backlog and works through it.

## How a session works

### You talk to the conductor

The conductor is the only agent that talks to you. It reports conclusions,
not transcripts:

```
Bottom line: sessions expire because the refresh job reads the old TTL key
Recommendation: read the TTL from the session config, migrate the old key
Other options: bump the TTL (hides the bug), rewrite refresh (too big for the gain)
Backlog: ttl-config - read TTL from config / ttl-migrate - migrate old key (checkpoint)
Decide: keep the old key readable for one release? (default: yes)
Cost so far: opus 41k out, sonnet 120k out, haiku 18k out
```

### It chooses the model for every task

You don't assign models. For each task the conductor picks the cheapest model
that can do it well:

| Model | Typical work |
|---|---|
| **haiku** | mapping where code lives, listing call sites, summarising the repo's rules and tooling, running tests and reporting failures |
| **sonnet** | investigation with a clear question, implementing an approved design, routine reviews, planning briefs |
| **opus** | stubborn root causes, proposals and designs with real architectural tradeoffs, review of risky changes, consultations |

When a teammate fails at something twice, the conductor replaces it with one
on the next model up. `worker.max-model` in `baton.conf` caps what it may use.

### It stays in the conversation

Teammates don't run hands-free:

- **Researchers** send their top hypotheses before tracing them, and the
  conductor pushes back until a root cause is backed by evidence.
- **The principal** checks its direction with the conductor before writing,
  and is the conductor's colleague for hard calls: the conductor consults it,
  debates it, then decides.
- **The implementer** sends its plan and waits for a "go", sends a progress
  note after each chunk (the conductor reads the diff and corrects it as it
  goes: "this doesn't follow the error-handling pattern in `src/lib/result.ts`"),
  and waits again before committing.
- **The reviewer** reviews independently, and the conductor challenges a
  verdict that isn't backed by evidence.

### It keeps to the repository's rules

At the start of a session a Haiku teammate summarises the repository's rules
(`CLAUDE.md`, contributing guides, lint and test commands, visible
conventions) into a short house-rules brief that every teammate gets. Teammates
also load `CLAUDE.md` themselves, like any Claude Code session.

### It watches the cost

Cheap models for mechanical work, warm teammates reused rather than respawned,
paths passed instead of documents pasted, a cap on review rounds, and
teammates shut down when their item closes. Every stop report includes the
session's token use, and `baton cost` shows it at any time.

### The roles

| Role | Job |
|---|---|
| **conductor** | Your point of contact. Plans the approach, chooses models, supervises, consults, decides, owns the kata backlog. Does no hands-on building. |
| **researcher** | Finds how the code works today and, for a problem, its root cause. Technical Brief. |
| **planner** | Settles product scope and acceptance criteria when they are open. Planning Brief. |
| **principal** | Solution Proposals, Implementation Designs, and advice to the conductor. |
| **implementer** | Builds, verifies and commits one item at a time. The only role that commits. |
| **reviewer** | Independent review of a proposal or an implementation: PASS or CHANGES REQUIRED. |

The prompts live in `prompts/`. `team-protocol.md` is appended to every
teammate's prompt and defines how it talks to the conductor.

## Requirements

- [Claude Code](https://code.claude.com/), logged in. Baton turns on agent
  teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) for its own sessions only.
- [`kata`](https://github.com/kenn-io/kata): the backlog lives in kata issues.
  Run `kata init` once per project; the conductor also does it if needed.
- [`gh`](https://cli.github.com/), authenticated: only for the default
  `feature` workflow, which publishes one pull request to a GitHub remote.
- `tmux` (optional): with it, every teammate gets its own pane. Without it,
  teammates run inside the conductor's terminal.
- `bash` 3.2+, `git`, `python3`.

## Install

```sh
git clone <this repo> ~/.baton
~/.baton/install.sh
```

`install.sh` is idempotent. It makes the scripts executable, creates
`baton.conf` from `baton.conf.example` if you don't have one (your
`baton.conf` is git-ignored), adds `~/.baton/bin` to your `PATH` in
`~/.zshrc` or `~/.bashrc`, and removes the Stop hook older baton releases
registered in `~/.claude/settings.json`.

Every `baton start` and `resume` writes the role agent definitions to
`~/.claude/agents/baton-<role>.md` from `prompts/`. Baton never overwrites a
file there that it didn't generate.

### Updating

```sh
baton update
```

Pulls the latest baton into your install (fast-forward only). It stops on
local changes to baton's files, a branch that doesn't track GitHub, or local
commits GitHub doesn't have. A running session keeps the prompts it started
with until you `baton stop` and `baton resume` it.

## Usage

```
baton start [--base BRANCH] [--workflow|-w feature|worktree] [--think] [--goal TEXT] [DIR]
                             Start a session for DIR (default: cwd) in its own git worktree
                             and open the conductor in this terminal
baton status [DIR]           List every session for DIR, running or stopped
baton resume [REF] [DIR]     Reopen a stopped session's conductor
baton stop [REF] [DIR]       End a running session's conductor
baton remove [REF] [DIR]     Stop and delete a session's Baton files and its worktree
baton cost [REF] [DIR]       Token use of a session, per model
baton config [DIR]           Show the resolved settings for DIR
baton update                 Pull the latest baton into this install
```

`REF` is a session id or, once the conductor has named the goal, its slug. It
is optional when `DIR` has one session. A directory can have several
sessions, each with its own worktree and marker dir under
`DIR/.baton/s/<id>/`. `baton start` adds `.baton/` to the repository's local
`.git/info/exclude`.

### The proposal phase

1. The conductor creates the goal's kata issue and tells you, in a few lines,
   how it understood the goal.
2. A researcher investigates; for a reported problem, until the root cause is
   established. A planner joins only if product questions are open.
3. The principal writes a **Solution Proposal**: two or three real options, a
   recommendation, a proposed backlog, and the decisions you should confirm.
4. The reviewer critiques it once and the principal answers each point.
5. The conductor brings you the bottom line and waits.

Reply with a question, a revision (which gets a fresh critique), or an
approval. On approval the conductor creates the backlog from the proposal and
starts delivering. Until then `baton-item start` refuses to begin any build.
Briefs, proposals and reviews live in the session's marker dir
(`.baton/s/<id>/docs/`) and are never committed.

### Session worktrees

`DIR` must be a git repository. Each `baton start` creates a branch
`baton/<uuid>` and a git worktree for it (under `~/.baton-worktrees/`, or
`$BATON_WORKTREE_DIR`), then opens the conductor inside that worktree; every teammate works there too. Your own
checkout, branch, and uncommitted changes are never touched, and two sessions
never share files. The marker dir stays under `DIR/.baton/s/<uuid>/`, and every
`baton` command still works from inside a session's worktree.

The session branch starts from `--base`:

- `--base main` starts from that local branch's committed tip.
- `--base origin/main` first fetches that branch, then starts from it.
- Without `--base`, baton uses the remote's default branch (`origin/HEAD`). If
  that can't be determined, for example in a repository with no remote, it
  stops and asks for `--base`.
- Tags and commit ids are rejected. With several remotes, name the remote
  (`--base origin/main`) instead of a bare local branch.

The base, its commit, and its remote are recorded in the marker dir
(`base_branch`, `base_ref`, `base_commit`, `remote`), along with
`workflow`, which says how the session turns backlog items into
branches and pull requests. It is fixed when the session starts, and `update`
and `resume` never change it.

| `workflow` | Chosen when | What a session produces |
|---|---|---|
| `feature` | the base is on a GitHub remote (the default there) | one session branch with the reviewed commits of every backlog item, and **one draft PR** for the whole goal ([details](#one-pr-per-feature)) |
| `worktree` | the base has no remote, or you pass `--workflow worktree` | one branch per backlog item, cut from trunk (or from an unmerged item it depends on), each with its own PR into trunk when the repository has a remote and `gh` is available |

Pass `--workflow` (or `-w`) to override the default, for example `-w worktree`
for a GitLab remote. Instances created by an older baton release have no
`workflow`; they run in `DIR` itself instead of a worktree.

### One PR per feature

A `feature` session turns the whole goal into **one draft pull request**
into the base branch. The conductor's backlog items are review steps, not PRs:
implementer commits each item directly on the session branch, reviewer checks
that exact commit, and only a PASS lets the next item start. Baton never merges
the PR. If a feature is too big for one PR, split the goal into smaller
sessions.

`baton start` needs `gh` installed and authenticated and a GitHub remote, and
stops before creating anything otherwise (`--workflow worktree` skips this).
Per item, the implementer and reviewer run `baton-item`:

- `start` records the commit the item starts from and refuses unless the
  proposal was approved, the checkout is clean on the session branch, and
  every earlier item passed.
- `complete` records the item's completed commit and its verification summary.
- `publish` pushes the branch (never force) and creates the draft PR once, or
  finds and reuses it, including after an interrupted create. Before the first
  push, `--branch` renames the `baton/<uuid>` placeholder to a conventional
  name such as `feat/venue-shutdown`. A PR that was
  closed or merged outside the session stops the session instead of opening a
  replacement.
- `review` records the verdict, the reviewed commit, and the report path, in
  the marker dir and as a Kata comment. Reports stay in the marker dir, so a
  review never changes the PR head.

The conductor accepts a reviewer PASS only when `baton-item gate` confirms the reviewed commit is the item's
completed commit, is the current session tip, and the checkout is clean. The
conductor closes an item only after `baton-item verify` confirms the record.

When the backlog is exhausted the conductor starts finalization: implementer
runs whole-feature verification and publishes, reviewer reviews the combined
diff against the base and the PR's checks, and the conductor runs
`baton-item ready --wait`, which marks the same PR ready only if the final PASS
is for the PR head and required checks passed. Failing checks go back to
implementer; pending checks leave finalization waiting (rerun `baton-item
ready --wait`). The goal is reported as "ready to merge", not "shipped".

`resume` leaves the checkout alone but refuses if it is on a different branch
than the session branch, then prints `baton-item status` (items, publication,
PR, finalization). `remove` also refuses while commits on the session branch
aren't on the remote; the PR may stay open.

A worktree is a fresh checkout, so it doesn't contain ignored files. `.env`
files, installed dependencies, databases, and port numbers are not shared or
isolated for you.

`baton stop` ends the conductor and keeps the checkout, branches, and state.
`baton resume` reopens the conductor in the same checkout. If startup
fails partway, the checkout is kept so `resume` can retry or `remove` can
clean up.

`baton remove` stops the session if it's running, deletes the worktree, then
deletes only `DIR/.baton/s/<uuid>/`. It refuses if the worktree has uncommitted
changes or ignored files (such as a hand-copied `.env`). The `baton/<uuid>`
branch and any item branches stay, so pushed or unpushed work isn't lost. Other runs, project files, kata items, and agent
transcripts stay.


### Resuming

`baton resume` reopens the conductor with a message telling it where the
session stands, so it picks up without being prompted. It is a fresh
conversation: Claude Code doesn't bring back agent-team teammates, so the
conductor spawns new ones as it needs them. Continuity comes from what's
durable: the kata backlog and its comments, the marker dir (briefs, reviews,
`baton-item` records), and the worktree.

### `--think`

`baton start --think` makes the run autonomous: during delivery the conductor
asks you nothing, and teammates decide product questions themselves and record
each as `Q -> A` for you to audit. The proposal still waits for your approval.

### Trust and permissions

`start`/`resume` mark the session worktree as trusted in Claude Code's profile,
so the conductor doesn't stall on the trust dialog. Teammates start with the
conductor's permission mode, and their permission prompts appear in the
conductor's terminal. Set `permission-mode` in `baton.conf` (for example
`acceptEdits`) to approve file edits up front, and pre-approve your usual
commands in Claude Code's own permission settings.

### Several items in flight

The conductor keeps up to `BATON_MAX_IN_FLIGHT` backlog items open at once
(default 2), so research and design for the next item can run while the
current one is built. Only one implementer builds at a time, and a `checkpoint`
item always runs alone and stops the run when it passes.

## Configuration

`baton.conf` (copied from `baton.conf.example` by `install.sh`), with
per-project overrides in `DIR/.baton/config`:

| Key | Default | Meaning |
|---|---|---|
| `conductor.model` | `opus` | The conductor's model |
| `conductor.effort` | `medium` | The conductor's effort: `low` to `max` |
| `worker.max-model` | `opus` | The most expensive model a teammate may get: `haiku`, `sonnet` or `opus` |
| `teammate-mode` | `auto` | `auto` (own tmux panes inside tmux), `tmux`, `iterm2` or `in-process` |
| `permission-mode` | Claude Code's default | Passed to the conductor's session, and so to its teammates |

`baton config DIR` shows what a directory resolves to.

## Backlog tracking

The backlog lives in [kata](https://github.com/kenn-io/kata):

- Each goal is one kata issue labeled `baton-backlog`; each backlog item is a
  child issue labeled `backlog-<slug>`, linked to the items it depends on with
  `--blocked-by`.
- Every issue also carries `baton-session-<id>`, so a session only sees its
  own issues even when two pick the same slug.
- Status is kata state: open and unowned is pending, claimed is in flight,
  closed is done. Only the conductor claims, comments decisions on, and closes
  items.

`baton status` summarises each session's backlog. If `BATON_MAX_ITEMS` is set,
the conductor stops after that many items.

## How it works

- `baton start` creates the worktree and marker dir, writes the agent
  definitions, writes the conductor's system prompt (`prompts/conductor.prompt.md`
  plus the session's facts: paths, workflow, allowed models, limits) to
  `.baton/s/<id>/conductor.prompt.md`, and then becomes `claude` in the
  worktree with agent teams enabled. Its pid is recorded, which is how
  `status` and `stop` know whether the session is running.
- The conductor spawns teammates with the Agent tool from the
  `baton-<role>` definitions, naming the model per task. Messages between
  them use Claude Code's team mailbox, and arrive without polling.
- `baton-item` records the commit, review and PR evidence of the feature
  workflow and refuses steps that would break it. Teammates find the session
  through `BATON_MARKER_DIR` or, when their shell lacks it, a pointer baton
  writes into the worktree's git dir.
- `baton-notify` shows a desktop notification (macOS or `notify-send`) when
  the conductor needs you.
- `baton cost` sums token use per model from the Claude Code transcripts of
  every session that ran in the worktree, the conductor and its teammates
  alike.

## Environment variables

| Variable | Set by | Meaning |
|---|---|---|
| `BATON_ROOT` | `baton` | The session worktree |
| `BATON_MARKER_DIR` | `baton` | The session's `.baton/s/<id>/` dir |
| `BATON_PROMPT_DIR` | you (optional) | Where the `.prompt.md` files live |
| `BATON_CONF` | you (optional) | The global `baton.conf` path |
| `BATON_AGENTS_DIR` | you (optional) | Where agent definitions are written (default `~/.claude/agents`) |
| `BATON_CLAUDE` | you (optional) | The Claude Code command (default `claude`) |
| `BATON_WORKTREE_DIR` | you (optional) | Where session worktrees are created (default `~/.baton-worktrees`) |
| `BATON_MAX_ITEMS` | you (optional) | Cap on backlog items per run |
| `BATON_MAX_IN_FLIGHT` | you (optional) | Backlog items open at once (default 2) |
| `BATON_THINK` | you (optional) | `1` turns on autonomous mode, like `--think` |
| `BATON_CHECK_TIMEOUT_SECONDS` | you (optional) | How long `baton-item ready --wait` waits for PR checks (default 1800) |
| `BATON_CHECK_POLL_SECONDS` | you (optional) | How often it polls them (default 30) |

The `BATON_MAX_*` and `BATON_THINK` values are read when you run
`baton start`/`resume` and written into the conductor's prompt; to change one,
`baton stop` and `baton resume` with the new value.

## Tests

Plain bash, no framework: `bash tests/<name>.sh` (`conductor`, `feature`,
`remove`, `status`, `update`, `worktree`). They stub `claude`, `kata` and `gh`,
and never launch real agents or touch GitHub.

## Limitations

- Agent teams are an experimental Claude Code feature; baton inherits its
  limits (no teammate resumption, one team per session, teammates can't spawn
  teammates).
- The conductor supervises through check-ins, the diff and the team mailbox.
  It sees what teammates report and what lands in the worktree, not every
  keystroke.
- Each teammate is its own Claude Code session, so a team costs more tokens
  than one session doing everything; the model routing and limits above are
  what keep that in check.
- Claude Code only. Support for other agent CLIs was removed with the pane
  runner; it can come back as a separate backend later.
