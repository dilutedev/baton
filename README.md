# baton

Hand a goal to a six-role pipeline of CLI agents and let it work through a
reviewed backlog while you do something else.

Baton is a [herdr](https://herdr.dev/)-based runner. Each role is its own agent
process in its own herdr pane, running with a fixed system prompt (its
"persona") for the life of the pane. Roles are independent: each picks its own
tool (`claude`, `codex`, or `omp`), model, and effort level. The moment a role
finishes a turn, `bin/baton-handoff` queues the next role's input and
`bin/baton-courier` types it into that role's pane, so a run can go from a
one-line goal to a backlog of shipped, reviewed changes largely unattended.

```
you ──goal──▶ conductor ──▶ researcher ──▶ planner ──▶ principal ⇄ reviewer ──▶ conductor ──▶ you
                                                          proposal   critique               approve

conductor ──▶ researcher ──▶ planner ──▶ principal ──▶ implementer ──▶ reviewer
    ▲                                                                     │
    └──────────────────────── PASS: next backlog item ────────────────────┘
```

Every run starts with a [proposal phase](#the-proposal-phase): the roles work
out what to build and the conductor brings you a recommendation and a proposed
backlog. Nothing is built until you approve it.

Inspired by [ayorcodes/claudespace](https://github.com/ayorcodes/claudespace).

- [Quick start](#quick-start)
- [The roles](#the-roles)
- [Requirements](#requirements) · [Install](#install)
- [Usage](#usage)
- [Configuration](#configuration)
- [Pane layout](#pane-layout--readability)
- [How it works](#how-it-works)
- [Environment variables](#environment-variables) · [Tests](#tests)

## Quick start

```sh
git clone <this repo> ~/.baton
~/.baton/install.sh          # then open a new shell

cd ~/code/my-project
kata init                    # once per project
baton start                  # pick tool/model/effort per role, then launch
```

Give the conductor pane your goal, or describe an issue. The pipeline
investigates it and comes back with a solution proposal (you get a desktop
notification). Reply in the conductor pane to approve it, or to ask for changes.
Once you approve, the conductor turns the proposal's backlog into kata items and
works through them.

## The roles

| Role | Job |
|---|---|
| **conductor** | Starts the proposal phase, brings you the proposal, turns the approved one into a backlog, keeps several items in flight (see [Several items in flight](#several-items-in-flight)), closes items on a reviewer PASS. The only role that touches the backlog. |
| **researcher** | Investigates how the current implementation works (for a reported problem, its root cause). |
| **planner** | Writes a Planning Brief. |
| **principal** | Writes the solution proposal, then an implementation design per item. |
| **implementer** | Implements the approved design. The only role that commits code, creates branches, and publishes pull requests (one per session under `feature`). |
| **reviewer** | Reviews the implementation and returns PASS or CHANGES REQUIRED. |

Each persona lives in `prompts/<role>.prompt.md`. Simple items can skip ahead
(for example straight to the implementer); the conductor decides per item.

## Requirements

- [`herdr`](https://herdr.dev/) (`herdr status` should show `server: running`)
- Whichever agent CLI(s) your roles use, on your PATH: `claude` (Claude Code),
  `codex`, and/or `omp`. You only need the ones you assign to a role.
- [`kata`](https://github.com/kenn-io/kata) - the backlog lives in kata issues
  (see [Backlog tracking](#backlog-tracking)). Run `kata init` once per project
  before its first `baton start`; the conductor also does this itself if it
  hasn't been done.
- [`gh`](https://cli.github.com/), authenticated (`gh auth login`) - only for the
  default `feature` workflow, which publishes one pull request to a GitHub
  remote (see [One PR per feature](#one-pr-per-feature))
- `uuidgen` (ships with macOS and most Linux distros)
- `bash` 3.2+ (the scripts avoid associative arrays for macOS's stock bash)
- `python3` - used by `install.sh` to merge the Stop hook into
  `~/.claude/settings.json` without clobbering your other hooks, and by
  `bin/baton` to parse herdr's JSON and to mark a project trusted in
  `~/.claude.json` before launching Claude panes

## Install

```sh
git clone <this repo> ~/.baton
~/.baton/install.sh
```

`install.sh` is idempotent, so it's safe to re-run. It:

1. Makes the scripts executable.
2. Creates `baton.conf` from `baton.conf.example` if you don't have one yet.
   Your `baton.conf` is git-ignored and never overwritten.
3. Warns if `herdr`, `kata`, or `uuidgen` aren't on PATH, and notes (without
   warning) which of `claude`/`codex`/`omp` aren't.
4. Appends `export PATH="$HOME/.baton/bin:$PATH"` to your `~/.zshrc` or
   `~/.bashrc` (whichever matches `$SHELL`) if it isn't already there.
5. Registers `hooks/baton-dispatch.sh` as a global Claude Code Stop hook in
   `~/.claude/settings.json`, if it isn't registered. It only adds an entry; your
   other hooks are untouched. The hook matters only for roles running Claude
   Code (see [How it works](#how-it-works)).

<details>
<summary>Doing it by hand</summary>

```sh
# in your shell rc
export PATH="$HOME/.baton/bin:$PATH"
```

```jsonc
// in ~/.claude/settings.json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.baton/hooks/baton-dispatch.sh", "timeout": 10 }
        ]
      }
    ]
  }
}
```

</details>

### Updating

```sh
baton update
```

This pulls the latest baton from GitHub into your install (the `~/.baton`
checkout `baton` runs from) and lists the new commits. It only fast-forwards:

- With uncommitted changes to baton's own files, it stops and lists them.
  Commit or `git stash` them in `~/.baton` first. Your `baton.conf` is
  git-ignored, so it never gets in the way.
- If `~/.baton` is on a branch that doesn't track one on GitHub (or isn't on a
  branch), it tells you to `git -C ~/.baton checkout main`.
- If your local branch has commits GitHub doesn't, it stops instead of merging.

Running instances keep the version they started with. To move one onto the
update, `baton stop` it and `baton resume` it.

## Usage

```
baton start [--base BRANCH] [--workflow|-w feature|worktree] [--think] [--yes] [DIR]
                                     Start a new instance for DIR (default: cwd) in its own git worktree
baton status [DIR]                   List every instance for DIR, running or stopped
baton attach [REF] [DIR]             Switch into a running instance (REF: slug or uuid)
baton resume [--yes] [REF] [DIR]     Relaunch a stopped instance's panes (fresh sessions, same instance)
baton stop [REF] [DIR]               Kill a running instance
baton remove [REF] [DIR]             Stop and delete one instance's Baton files and its worktree
baton config [DIR]                   Show each role's resolved tool/model/effort/layout for DIR
baton update                         Pull the latest baton from GitHub into this install
```

`REF` is optional whenever `DIR` has exactly one instance. A run gets a short
uuid; once its conductor persists a backlog, the run also gets the backlog's
`slug`, so you can address it by name.

A directory can have several concurrent runs, each with its own herdr
workspace and marker dir under `DIR/.baton/s/<uuid>/`. `baton start` adds
`.baton/` to the repository's local `.git/info/exclude`, so your tracked files
stay untouched: it's per-project runtime state (hand-off markers, dispatch
bookkeeping), not something to commit.

### The proposal phase

A goal never goes straight into a backlog. First:

1. The conductor creates the goal's kata issue and hands the goal to the researcher.
2. The researcher investigates. For a reported problem, its Technical Brief has
   to establish the root cause.
3. The planner writes a Planning Brief, if there are product questions.
4. The principal writes a **Solution Proposal**: two or three options with
   their tradeoffs, a recommendation, a proposed backlog, and the decisions
   you should confirm.
5. The reviewer critiques the proposal once, and the principal answers each
   point.
6. The conductor reports the proposal in its pane, sends a desktop
   notification, and waits.

Reply in the conductor pane. Ask a question, ask for a revision (which goes
back to the principal and gets a fresh critique), or approve. On approval the
conductor creates the backlog items from the proposal and starts dispatching;
there is no separate backlog review.

While the goal is in this phase, `baton-handoff` refuses any handoff to the
implementer and a second critique in the same round. The proposal and briefs
stay under the session's marker dir (`.baton/s/<uuid>/proposal-docs/`), shared
by every item and never committed, so `baton remove` deletes them.

### Session worktrees

`DIR` must be a git repository. Each `baton start` creates a branch
`baton/<uuid>` and a git worktree for it (under `~/.baton-worktrees/`, or
`$BATON_WORKTREE_DIR`), then launches every role inside that worktree. Your own
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
Per item, roles run `baton-item`:

- `start` records the commit the item starts from and refuses unless the
  checkout is clean on the session branch and every earlier item passed.
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

`baton-handoff` refuses a reviewer PASS unless the reviewed commit is the item's
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

`baton stop` closes the session's workspace and keeps the checkout, branches,
and state. `baton resume` relaunches the roles in the same checkout. If startup
fails partway, the checkout is kept so `resume` can retry or `remove` can
clean up.

`baton remove` closes the run if it's running, deletes the worktree, then
deletes only `DIR/.baton/s/<uuid>/`. It refuses if the worktree has uncommitted
changes or ignored files (such as a hand-copied `.env`). The `baton/<uuid>`
branch and any item branches stay, so pushed or unpushed work isn't lost. Other runs, project files, kata items, and agent
transcripts stay.

### The start/resume screen

`start` and `resume` open a full-screen TUI over every role's
tool/model/effort instead of making you pass flags:

```
↑/↓ role   Tab field   ←/→ change   s save & launch   q quit without launching
```

- `↑`/`↓` move between roles, `Tab` between the tool/model/effort columns, and
  `←`/`→` cycle the focused column.
- Nothing is free text. Models come from [`models.json`](#selecting-models).
  Switching a role's tool snaps its model to that tool's first entry, since a
  model id from one tool generally isn't valid for another.
- `s` saves every role's value to `DIR/.baton/config` and launches. `q`, Ctrl-C,
  or a bare Escape abandons the whole command without saving or launching.
- On `start` the screen seeds from what `baton.conf` resolves to. On `resume`
  it seeds from what was actually used last time (whatever an earlier save left
  in `DIR/.baton/config`).
- `--yes`/`-y` skips the screen. It's also skipped automatically when stdin
  isn't a terminal.

### Resuming

`baton resume` doesn't reconnect a role to its old conversation. Every launch
is a fresh session for whatever tool/model/effort the role currently resolves
to. That's deliberate: you can `baton stop`, switch a role from `claude` to
`codex` (or change its model or effort), and `baton resume` just uses the new
setup, with no session format to migrate.

Continuity comes from what's durable in the project: the kata backlog and its
comment history. Any role can rebuild what's in flight from `kata list` /
`kata show`. Resume also types a short nudge into the conductor pane telling it
to find the active backlog and keep dispatching, so you don't have to
re-prompt it by hand.

### `--think`

`baton start --think DIR` drops a `think` marker file in the run's marker dir.
The role prompts check for it and, when present, spend more deliberation on
each turn at the cost of speed. Leave it off for routine runs.

### Trust

`start`/`resume` mark `DIR` as trusted in Claude Code's own profile (the field
Claude Code sets when you answer "Yes, I trust this folder") before launching
Claude panes. Naming `DIR` to `baton` is already that trust decision. Without
it, a Claude pane would stall on the dialog with nobody watching. Other tools
handle their own approval prompts independently.

### Several items in flight

The pipeline works like an assembly line. Each role works on one item at a
time, but not necessarily the same one: while implementer builds one item,
researcher, planner and principal are already preparing the next ones. With a
backlog of independent features F1, F2, F3, ...:

```
time →           t1    t2    t3    t4    t5    t6
researcher       F1    F2    F3    F4    F5    F6
planner                F1    F2    F3    F4    F5
principal                    F1    F2    F3    F4
build                              F1    F2    F3   (implementer + reviewer)
```

(In practice stages take different amounts of time and items can skip
researcher or planner - see "Choosing where to dispatch" in
`prompts/conductor.prompt.md` - so it's rarely this tidy.)

The conductor claims up to **`BATON_MAX_IN_FLIGHT`** items (default **4**) at
once and dispatches each as normal. A handoff to a role that's still busy
waits in that role's queue (`.dispatch-state/<role>.queue`) until
`bin/baton-courier` can deliver it. After each reviewer PASS, the conductor
closes that item and claims the next one, so a 10-item backlog moves through
four at a time until it's done.

**Choosing the limit.** Four means one item being built plus one each for
researcher, planner and principal, so every pane can be busy at once. The
build stage (implementing, then review rounds) is usually the slowest, so
designs finish faster than they're built and wait for implementer. The higher
the limit, the further ahead of the build those designs are written, and the
more likely the code has changed underneath them by the time they're built.

| `BATON_MAX_IN_FLIGHT` | Behaviour |
|---|---|
| `1` | One item at a time through the whole pipeline. Slowest, no overlap at all. |
| `2`-`3` | Some overlap; one or two design panes sit idle while an item is built. |
| `4` (default) | Every pane can be busy; at most a design or two waits for the build. |
| `5`+ | More designs queue up waiting for implementer and are more likely to go stale. Rarely worth it, since implementer still builds one at a time. |

Set it in the environment of `baton start` or `baton resume` (it's passed into
the panes, and a resume picks up the new value):

```bash
BATON_MAX_IN_FLIGHT=2 baton start .
```

**What keeps items from affecting each other:**

- Dependencies: the conductor only dispatches what `kata next` returns, and
  `--blocked-by` keeps an item out until everything it depends on is closed.
  If every item depends on the one before it, nothing overlaps - correct, just
  sequential. Independent items overlap fully.
- Implementer builds strictly one item at a time: once it takes an item, it
  only gets that item's handoffs (fixes after CHANGES REQUIRED, answers to its
  questions) until reviewer passes it. All panes share one checkout, so the
  next item's build waits for this one to be done: its branch under
  `worktree`, its reviewed commit on the session branch under `feature`.
- Stale designs: implementer re-checks each design against the code before
  building, and bounces it to principal if it no longer fits.
- Context: a pane is sent `/clear` whenever it switches to a different item
  (see below).
- Design artifacts are staged. In a conductor-driven run, researcher, planner
  and principal write their briefs and designs to
  `.baton/s/<instance>/staging/<item>/` (gitignored, at the same relative
  paths they'd have in the repo) instead of the checkout, which may be on
  another item's branch. Implementer moves them into the repo and commits them
  with the code: on the item's own branch under `worktree`, on the session
  branch under `feature`.
- An item labeled `checkpoint` runs alone, so the run can pause after it.

**Known limits:**

- Researcher, planner and principal still *read* code in the shared checkout,
  which is on whatever branch implementer is building. Staging only keeps
  their *writes* off it.
- `baton resume` with several items in flight: each role's unfinished turn is
  lost when the run stopped, and the conductor's resume nudge only names the
  most recently dispatched item. Check `kata list` and re-dispatch stuck items
  if needed.

### Mid-run `/clear`

When the courier hands a pane a different backlog item than the one it last
worked on, it sends `/clear` first, so one item's context doesn't leak into
the next. Claude, codex and omp all accept `/clear` while idle.

## Configuration

Per-role `tool`, `model`, and `effort`, plus the window `layout`, come from
config files. The most specific value wins:

```
<project>/.baton/config   ->  <role>.<key>       (most specific)
<project>/.baton/config   ->  default.<key>
baton.conf                ->  <role>.<key>
baton.conf                ->  default.<key>
built-in fallback         ->  tool=claude, model=sonnet, effort=high, layout=tiled
```

The global `baton.conf` lives next to `bin/` in your baton checkout (for
example `~/.baton/baton.conf`); set `$BATON_CONF` to use a different path. It's
your local copy and is git-ignored: `install.sh` creates it from
`baton.conf.example`, and without one baton uses the built-in fallbacks.

| Key | Values |
|---|---|
| role | `conductor`, `researcher`, `planner`, `principal`, `implementer`, `reviewer` |
| `tool` | `claude`, `claude2`, `codex`, or `omp` - which CLI agent runs the role. `claude2` is Claude Code on a second account: same CLI and models, but with `CLAUDE_CONFIG_DIR=~/.claude-secondary`, so it uses that account's login, settings, and hooks |
| `model` | an alias or model name meaningful to that tool (`sonnet`/`opus` for `claude`, `gpt-5.x`-style names for `codex`) |
| `effort` | `low`, `medium`, `high`, `xhigh`, `max` |
| `layout` | `tiled`, `main-vertical`, `main-horizontal` (top level, no role prefix) |

Example:

```
default.tool=claude
default.model=sonnet
default.effort=high

conductor.effort=medium
implementer.tool=codex
implementer.model=gpt-6-sol
implementer.effort=medium

layout=tiled
```

To override just one project, create `<project>/.baton/config` with the same
syntax. Run `baton config [DIR]` any time to see exactly what a directory would
launch with. Because every launch is a fresh session, you can change a role's
settings freely between `baton stop` and `baton resume`.

### Selecting models

The start/resume screen never takes a typed model name. Each tool's valid model
ids change over time and baton can't discover them from a flag, so free text
was a good way to end up with a silently misconfigured role. Instead, `←`/`→` on
the model column cycles through that tool's list in `models.json` (next to
`bin/`; override the path with `$BATON_MODELS`):

```json
{
  "claude": ["sonnet", "opus", "haiku"],
  "codex": ["gpt-6-sol", "gpt-6.1-sol", "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.5"],
  "omp": ["kimi-k3", "kimi-k2.6", "kimi-k2.7-code"]
}
```

Edit it to add, remove, or reorder models. The first entry is what a role's
model snaps to when you switch it to that tool. Changes are picked up on the
next `start`/`resume`, no reinstall. The schema is just tool name to an array of
strings: whatever that tool's own model flag accepts. If the file is missing,
invalid, or has nothing for a tool, `←`/`→` on the model column does nothing
and the role keeps its model.

This only curates the interactive picker. `baton.conf` and
`DIR/.baton/config` still accept any string for `<role>.model`, so you can
hand-edit in a model that isn't listed yet.

### Adding a tool

How each tool takes a model, an effort level, and a persona is mapped in
`tool_launch_args` and `tool_needs_typed_persona` in `bin/baton`. `claude`,
`codex`, and `omp` are implemented. To wire up another `herdr agent start
--kind` value (see `herdr agent start --help`), add a case there once you've
confirmed that tool's real flags; baton doesn't guess.

### Using z.ai / GLM models

Set a `claude`-tool role's `model` to a z.ai model name (`glm-*`, for example
`glm-5.3` or `glm-5.3-flash`). `spawn_pipeline_panes` detects the prefix and
points that pane's `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` at z.ai using
`$ZAI_API_KEY`, so plain `claude` talks to z.ai without a wrapper. `ZAI_API_KEY`
must be set wherever you run `baton start`/`resume`; baton exits with an error
naming the role if a `glm-*` role is configured and it isn't.

## Backlog tracking

The conductor creates the backlog from the approved proposal, but it lives in
[kata](https://github.com/kenn-io/kata), not a markdown file.

- Each goal is one kata issue labeled `baton-backlog`.
- Each backlog item is a child issue labeled `backlog-<slug>`, linked to the
  items it depends on with kata's `--blocked-by`.
- Every issue also carries `baton-session-<session>`, so `baton resume` and the
  conductor only see the issues of *this* session, even if two sessions pick
  the same slug.
- Status is kata state: open and unowned is pending, claimed is in progress,
  closed is done, and an open item that `kata ready`/`kata next` won't surface
  yet is blocked.
- Only the conductor claims, closes, or edits items.

The first time it sees a goal, the conductor writes the backlog and **stops**.
Review or edit it in kata (`kata edit`, `kata label`, ...) and tell the
conductor to continue. `kata list --label backlog-<slug> --agent` shows what
`baton status` summarizes per run. If `BATON_MAX_ITEMS` is set when you run
`baton start`/`resume`, the conductor stops after that many items (counting
items still in flight, so it never starts more than that).

## Pane layout & readability

By default all six panes are `tiled`, a rough grid built from binary splits
(herdr panes are a BSP tree, not a named grid). That's fine on a big monitor;
on a laptop, six equal panes are each too small to read comfortably. Two fixes:

1. **Zoom the pane you're reading.** herdr's pane zoom toggles the focused pane
   to fullscreen and back. No config needed, and usually the fastest fix since
   you mostly read one role (often the conductor) at a time.
2. **Change the default layout.** Set `layout` in `baton.conf` (global or
   per-project):
   - `tiled` - equal grid (default)
   - `main-vertical` - conductor gets a large pane on the left; the other five
     stack in a narrower column on the right
   - `main-horizontal` - conductor gets a large pane on top; the other five sit
     in a shorter row underneath

   The conductor is always the main pane, since it's the one you talk to. Zoom
   still works on any pane. `layout` is a tab-level setting, so it takes no
   role prefix.

## How it works

- **`bin/baton`** is the CLI. It creates the herdr workspace/tab, splits one
  pane per role, resolves each role's tool/model/effort, and starts the tool in
  each pane with `herdr agent start <role>-<instance> --kind <tool> ...`, setting
  `BATON_ROOT`, `BATON_MARKER_DIR`, and `BATON_ROLE` in the pane's environment.
  `tool_launch_args` maps model, effort, and persona onto each tool's CLI: a
  real system-prompt file flag for `claude`, `-c key=value` overrides for
  `codex`, and for any tool without a system-prompt flag the persona is typed in
  as the pane's first message (`tool_needs_typed_persona`). The role-to-agent
  mapping is recorded in `$marker_dir/agents.map`.
- **`bin/baton-handoff --status done|blocked [--route ROLE] "<payload>"`** is
  what a role runs when it finishes or bounces a turn.
  - It records the handoff: a kata comment on the current backlog item (the
    normal, conductor-driven case) or, with no item to comment on, a local
    `$BATON_MARKER_DIR/<role>.done`/`<role>.blocked` file.
  - It picks the next role: an explicit `--route`, or the fixed order
    researcher → planner → principal → implementer → reviewer → conductor →
    researcher.
  - It queues the payload for that role in
    `.dispatch-state/<role>.queue` (bounces go to the front). It never calls
    herdr itself, so it works the same inside `claude`, `codex` (sandboxed), and
    `omp` panes.
- **`bin/baton-courier`** runs in the background for each instance (`baton
  start`, `resume` and `attach` launch it; it exits once the instance's tab is
  gone). Every second it types each role's next queued payload into its pane
  with `herdr agent prompt`, once that role has handed off its current item and
  herdr reports its turn over. A pane switching to a different backlog item is
  sent `/clear` first. This is what lets several items be in flight at once:
  work for a busy role waits in its queue instead of interrupting it.
- **`bin/baton-item`** records and checks a `feature` session's evidence:
  each item's start, completed and reviewed commits, the one draft PR
  (`publish`), and finalization (`final-start`, `final-review`, `ready`). It
  runs inside the role's own shell, like `baton-handoff`, and
  `baton-handoff` calls its `gate` to refuse a reviewer PASS without matching
  evidence. See [One PR per feature](#one-pr-per-feature).
- **`bin/baton-notify "<text>"`** queues a desktop notification. The
  conductor runs it whenever it stops and needs you. Like `baton-handoff` it
  only writes to `.dispatch-state/`, and the courier shows it (`osascript` on
  macOS, `notify-send` where available, otherwise nothing).
- **`bin/baton-msg <role> "<text>"`** is fire-and-forget: it types text into
  another role's pane (for example the conductor poking a stuck implementer). It
  never waits for a reply and never advances the pipeline.
- **`hooks/baton-dispatch.sh`** is a Claude Code Stop hook, registered globally.
  It exits instantly for any session that isn't a baton pane, and does nothing
  for non-Claude panes (other tools have no equivalent hook). For a Claude pane
  on a conductor-driven run, it catches a role ending a turn without calling
  `baton-handoff`. It compares the timestamp `baton-handoff` leaves in
  `.dispatch-state/` with the last one it credited. If no handoff landed, it
  blocks the Stop twice with a reminder to finish the handoff. If a third turn
  still ends without one, it stops nagging and pings the conductor pane once, so
  a human notices the stall instead of the pipeline going quiet. Once a role has
  handed off, it isn't nudged again until the courier delivers it new work, so
  idle turns don't trigger a repeat handoff. Manually-driven
  chains (no `$BATON_MARKER_DIR/conductor-run`) are skipped, since a human is
  watching.
- **`prompts/*.prompt.md`** are the six personas, loaded through each tool's
  system-prompt mechanism (or typed as the first message) for the life of the
  pane.

## Environment variables

| Variable | Set by | Meaning |
|---|---|---|
| `BATON_ROOT` | `baton` | The run's working directory: its session worktree (or the project directory for instances created by an older baton release) |
| `BATON_MARKER_DIR` | `baton` | This run's `.baton/s/<uuid>/` dir |
| `BATON_ROLE` | `baton` | This pane's role name |
| `BATON_PROMPT_DIR` | you (optional) | Override where role `.prompt.md` files live |
| `BATON_CONF` | you (optional) | Override the global `baton.conf` path |
| `BATON_MODELS` | you (optional) | Override the `models.json` path |
| `BATON_WORKTREE_DIR` | you (optional) | Where session worktrees are created (default `~/.baton-worktrees`) |
| `BATON_MAX_ITEMS` | you (optional) | Cap on backlog items the conductor completes in a run |
| `BATON_MAX_IN_FLIGHT` | you (optional) | How many backlog items the conductor keeps in flight at once (default 4, `1` = one at a time). See [Several items in flight](#several-items-in-flight) |
| `BATON_THINK` | you (optional) | `1` turns on autonomous mode, same as `baton start --think` |
| `BATON_CHECK_TIMEOUT_SECONDS` | you (optional) | How long `baton-item ready --wait` waits for pending PR checks (default 1800) |
| `BATON_CHECK_POLL_SECONDS` | you (optional) | How often `baton-item ready --wait` polls the checks (default 30) |
| `ZAI_API_KEY` | you (for `glm-*` models) | z.ai API key, see [Using z.ai / GLM models](#using-zai--glm-models) |

`BATON_MAX_ITEMS`, `BATON_MAX_IN_FLIGHT` and `BATON_THINK` are read when you
run `baton start`/`resume` and passed into every pane (panes don't otherwise
see the environment `baton` runs in). To change one mid-run, `baton stop` and
`baton resume` with the new value.

## Tests

The scripts in `tests/` are plain bash with no framework; run one with
`bash tests/<name>.sh` (`claude2`, `courier`, `dispatch`, `env`, `handoff`,
`nudge`, `remove`, `status`, `update`, `worktree`, `feature`). `worktree` covers
base resolution and the session worktree lifecycle against stubbed herdr and
kata. `feature` covers the `feature` item gate, publication, finalization,
resume and remove against a local bare repository, with `gh` stubbed. Neither
launches real agents or touches GitHub; `tests/spike/` holds the manual
sandbox and handoff probes for real panes.
