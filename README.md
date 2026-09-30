# baton

Hand a goal to a six-role pipeline of CLI agents and let it work through a
reviewed backlog while you do something else.

Baton is a [herdr](https://herdr.dev/)-based runner. Each role is its own agent
process in its own herdr pane, running with a fixed system prompt (its
"persona") for the life of the pane. Roles are independent: each picks its own
tool (`claude`, `codex`, or `omp`), model, and effort level. The moment a role
finishes a turn, `bin/baton-handoff` types the next role's input into its
pane, so a run can go from a one-line goal to a backlog of shipped, reviewed
changes largely unattended.

```
you ──goal──▶ conductor ──▶ researcher ──▶ planner ──▶ principal ──▶ implementer ──▶ reviewer
                  ▲                                                                     │
                  └──────────────────────── PASS: next backlog item ────────────────────┘
```

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

Give the conductor pane your goal. It decomposes the goal into a backlog, stops
for you to review it, and only starts dispatching once you tell it to continue.

## The roles

| Role | Job |
|---|---|
| **conductor** | Turns a goal into a backlog, dispatches one item at a time, closes items on a reviewer PASS. The only role that touches the backlog. |
| **researcher** | Investigates how the current implementation works. |
| **planner** | Writes a Planning Brief. |
| **principal** | Produces an implementation design. |
| **implementer** | Implements the approved design. The only role that creates branches and pull requests. |
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

## Usage

```
baton start [--think] [--yes] [DIR]  Start a new instance for DIR (default: cwd)
baton status [DIR]                   List every instance for DIR, running or stopped
baton attach [REF] [DIR]             Switch into a running instance (REF: slug or uuid)
baton resume [--yes] [REF] [DIR]     Relaunch a stopped instance's panes (fresh sessions, same instance)
baton stop [REF] [DIR]               Kill a running instance
baton remove [REF] [DIR]             Stop and delete one instance's Baton files
baton config [DIR]                   Show each role's resolved tool/model/effort/layout for DIR
```

`REF` is optional whenever `DIR` has exactly one instance. A run gets a short
uuid; once its conductor persists a backlog, the run also gets the backlog's
`slug`, so you can address it by name.

A directory can have several concurrent runs, each with its own herdr
workspace/tab and marker dir under `DIR/.baton/s/<uuid>/`. `baton start` adds
`.baton/` to that directory's `.gitignore` if it's inside a git repo: it's
per-project runtime state (hand-off markers, dispatch bookkeeping), not
something to commit.

Run `baton start`/`resume` from inside a herdr pane and it adds a tab to your
current workspace; from outside herdr it creates a dedicated workspace. Either
way, `baton stop` closes only what that run created, never your other panes.

`baton remove` closes the run if it's running, then deletes only
`DIR/.baton/s/<uuid>/`. Other runs, project files, kata items, and agent
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

### Mid-run `/clear`

Between backlog items, the conductor sends `/clear` to the other five panes
(see "Dispatching an item" in `prompts/conductor.prompt.md`) so one item's
context doesn't leak into the next. `/clear` is Claude Code's own command. A
role on another tool needs that tool's equivalent, and the prompts don't
branch on this yet.

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
| `tool` | `claude`, `codex`, or `omp` - which CLI agent runs the role |
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

The conductor decomposes a goal into a backlog, but the backlog lives in
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
`baton status` summarizes per run. If `BATON_MAX_ITEMS` is set in the
environment, the conductor stops after that many items.

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
  - It sends the payload into that pane with `herdr agent prompt`.
  - It's a plain shell command, so it works the same for `claude`, `codex`, and
    `omp` panes.
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
  handed off, it isn't nudged again until `baton-handoff` from the previous role
  sends it new work, so idle turns don't trigger a repeat handoff. Manually-driven
  chains (no `$BATON_MARKER_DIR/conductor-run`) are skipped, since a human is
  watching.
- **`prompts/*.prompt.md`** are the six personas, loaded through each tool's
  system-prompt mechanism (or typed as the first message) for the life of the
  pane.

## Environment variables

| Variable | Set by | Meaning |
|---|---|---|
| `BATON_ROOT` | `baton` | The project directory the run was started for |
| `BATON_MARKER_DIR` | `baton` | This run's `.baton/s/<uuid>/` dir |
| `BATON_ROLE` | `baton` | This pane's role name |
| `BATON_PROMPT_DIR` | you (optional) | Override where role `.prompt.md` files live |
| `BATON_CONF` | you (optional) | Override the global `baton.conf` path |
| `BATON_MODELS` | you (optional) | Override the `models.json` path |
| `BATON_MAX_ITEMS` | you (optional) | Cap on backlog items the conductor completes in a run |
| `ZAI_API_KEY` | you (for `glm-*` models) | z.ai API key, see [Using z.ai / GLM models](#using-zai--glm-models) |

## Tests

The scripts in `tests/` are plain bash with no framework; run one with
`bash tests/<name>.sh` (`nudge`, `remove`, `status`).
