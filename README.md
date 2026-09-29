# baton

A [herdr](https://herdr.dev/)-based runner for a 6-role pipeline:
**conductor → researcher → planner/principal → implementer → reviewer**. Each
role is a separate CLI agent process in its own herdr pane, running with a
fixed system prompt (its "persona") for the life of the pane. Baton isn't tied
to one agentic tool - each role independently picks which tool (`claude`,
`codex`, or `omp`), model, and effort level it runs with, via `baton.conf`.
The moment a role finishes a turn, `bin/baton-handoff` types the next role's
input into its pane directly, so a run can go from a one-line goal to a
reviewed backlog of shipped changes largely unattended, regardless of which
tools are running which roles.

```
you: baton start ~/code/my-project
     -> give the conductor pane a goal
conductor -> researcher -> planner -> principal -> implementer -> reviewer -> conductor -> ...
             (loops per backlog item until the backlog is exhausted, blocked, or capped)
```

Inspired by [ayorcodes/claudespace](https://github.com/ayorcodes/claudespace).

## Requirements

- [`herdr`](https://herdr.dev/) (`herdr status` should show `server: running`)
- whichever CLI agent(s) your roles are configured to use - `claude` (Claude
  Code), `codex` (Codex CLI), and/or `omp`, on your PATH. Only need the ones
  you've actually assigned to a role in `baton.conf`.
- [`kata`](https://github.com/kenn-io/kata) - the conductor persists the
  backlog as kata issues (see [Backlog tracking](#backlog-tracking) below)
  rather than a markdown file; run `kata init` once in a project before its
  first `baton start` (the conductor also does this itself if it
  hasn't been done yet)
- `uuidgen` (ships with macOS and most Linux distros)
- `bash` 3.2+ (the scripts avoid associative arrays for macOS's stock bash)
- `python3` - used by `install.sh` to merge the Stop hook into
  `~/.claude/settings.json` without clobbering any other hooks you have, and
  by `bin/baton` itself to parse herdr's JSON responses and to mark a
  project trusted in `~/.claude.json` before launching Claude panes

## Install

```
git clone <this repo> ~/.baton
~/.baton/install.sh
```

`install.sh` is idempotent - safe to re-run. It:

1. Makes the scripts executable.
2. Warns if `herdr`, `kata`, or `uuidgen` aren't on PATH, and notes (without
   warning) which of `claude`/`codex`/`omp` aren't - you only need the ones
   you actually assign to a role.
3. Appends `export PATH="$HOME/.baton/bin:$PATH"` to your `~/.zshrc` or
   `~/.bashrc` (whichever matches `$SHELL`), if that line isn't already
   there.
4. Registers `~/.baton/hooks/baton-dispatch.sh` as a global Stop hook in
   `~/.claude/settings.json`, if it isn't already registered. This only adds
   an entry to that hook list - it doesn't touch any other hooks you have
   configured. This hook only matters for roles running Claude Code (see
   [How it works](#how-it-works) below); it's a no-op pane for any other tool.

If your shell isn't zsh or bash, or you'd rather do it by hand, the two
things `install.sh` does for you are:

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

Open a new shell after installing, then run `baton start` inside any
project directory.

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

`REF` is optional whenever `DIR` has exactly one instance. A "run" gets a
short uuid; once its conductor persists a backlog, the run also gets a
`slug` (the backlog's own slug) so you can address it by name instead of by
uuid.

A directory can have multiple concurrent runs, each its own herdr
workspace/tab and its own marker dir under `DIR/.baton/s/<uuid>/`.
`baton start` adds `.baton/` to that directory's `.gitignore`
automatically if it's inside a git repo - this is per-project runtime state
(hand-off markers, dispatch bookkeeping), not something to commit.

Both commands open with a full-screen, arrow-key TUI over every role's
tool/model/effort instead of making you pass flags:

```
↑/↓ role   Tab field   ←/→ change   s save & launch   q quit without launching
```

`↑`/`↓` move between roles, `Tab` moves between the tool/model/effort
columns, and `←`/`→` cycle whichever column is focused: `tool`
(`claude`/`codex`/`omp`), `model` (that role's *tool's* entry in
[`models.json`](#selecting-models) - switching a role's tool snaps its model
to the new tool's first entry, since a model id from the old tool generally
isn't valid for the new one), or `effort`
(`low`/`medium`/`high`/`xhigh`/`max`). Nothing here is free text - see
[Selecting models](#selecting-models) for why and how to add one.
`s` saves every role's current value to `DIR/.baton/config` and launches;
`q` (or Ctrl-C, or a bare Escape) abandons the whole `start`/`resume` - it
exits without saving anything or launching any panes. On `baton start` the
screen seeds from whatever `baton.conf` currently resolves to; on `baton
resume` it's whatever
was actually used last time, since a previous save's edits are what's
sitting in `DIR/.baton/config` now. Pass `--yes`/`-y` to skip the screen
outright (useful in scripts, or when stdin isn't a terminal - it's skipped
there automatically either way). See [Configuration](#configuration) for the
underlying mechanics.

`baton resume` doesn't reconnect a role to its previous underlying
conversation - every launch is a fresh session for whatever tool/model/effort
that role currently resolves to in `baton.conf`. That's deliberate: it means
you can `baton stop`, change a role's `tool` (say, from `claude` to `codex`)
or its `model`/`effort`, and `baton resume` just picks up the new
configuration - there's no session format to migrate between tools.
Continuity comes from what's already durable in the project directory: the
kata backlog and its comment history. Point any role at `kata
list`/`kata show` and it can reconstruct what's in flight regardless of which
tool ran it before. `baton resume` also automatically types a short nudge
into the conductor pane telling it to resolve the active backlog and keep
dispatching - so resuming under a different tool/model doesn't need you to
separately remember to re-prompt it by hand.

Run `baton start`/`resume` from inside an existing herdr pane and it
adds a tab to your current workspace; run it from outside herdr and it
creates a dedicated workspace. Either way, `baton stop` only ever
closes what that run itself created - a tab it added to your workspace, or
a workspace it created outright - never the rest of your panes.

`baton remove [REF] [DIR]` closes the selected run if it is running, then
deletes only `DIR/.baton/s/<uuid>/`. It leaves other runs, project files,
kata backlog items, and Claude conversation transcripts in place. Specify
`REF` when the directory has more than one run.

### `--think`

`baton start --think DIR` drops a `think` marker file in the run's
marker dir. The role prompts check for it and, when present, spend more
deliberation on each turn (at the cost of speed). Leave it off for routine
runs.

### Trust

`baton start`/`resume` mark `DIR` as trusted in Claude Code's own profile
(the same field Claude Code itself sets when you answer "Yes, I trust this
folder") before launching any Claude panes. Naming `DIR` to `baton` already
is that trust decision - without this, a Claude pane would otherwise stall on
that dialog with no one watching to answer it, since herdr's `agent start`
(unlike a blind tmux `send-keys`) actually waits for the launched agent to
become interactive-ready. Other tools handle their own trust/approval
prompts independently of baton.

### Mid-run `/clear`

Between backlog items, the conductor sends `/clear` to the other 5 panes
(see `prompts/conductor.prompt.md`'s "Dispatching an item") so a role's
turns from the previous item don't ride along into the next one. `/clear`
is Claude Code's own slash command; a role running a different tool needs
that tool's equivalent instead (the prompts don't branch on this yet - see
[Configuration](#configuration) if you're assigning `codex`/`omp` to a role
that's dispatched mid-backlog rather than just at start/resume). Since baton
never resumes a role's previous session anyway (see [Usage](#usage) above),
there's nothing to keep in sync afterward either way.

### Backlog tracking

The conductor decomposes a goal into a backlog and drives the pipeline
through it, same as always - but the backlog itself lives in
[kata](https://github.com/kenn-io/kata), not a `docs/backlog-<slug>.md`
file. Each goal becomes one kata issue (labeled `baton-backlog`); each
backlog item becomes a child kata issue (labeled `backlog-<slug>`), linked
to the items it depends on via kata's `--blocked-by` relationship instead of
a hand-rolled `requires:` field. Item status is just kata issue state - open
and unowned is pending, claimed is in-progress, closed is done, and an open
item kata's own dependency graph won't surface yet (via `kata ready`/`kata
next`) is blocked. The conductor is still the only role that ever claims,
closes, or edits a backlog item; `kata list --label backlog-<slug> --agent`
in the project directory shows you the same thing `baton status`
already summarizes per run.

## Configuration

Per-role `tool`/`model`/`effort`, plus the window `layout` (see [Pane layout &
readability](#pane-layout--readability) below), come from a `baton.conf`
file, with project-level settings winning over global ones:

```
<project>/.baton/config   ->  <role>.<key>       (most specific)
<project>/.baton/config   ->  default.<key>
~/.baton/baton.conf ->  <role>.<key>        ($BATON_CONF overrides the path)
~/.baton/baton.conf ->  default.<key>
built-in fallback               ->  tool=claude, model=sonnet, effort=high, layout=tiled
```

Roles: `conductor`, `researcher`, `planner`, `principal`, `implementer`,
`reviewer`. `tool` is `claude`, `codex`, or `omp` - which CLI agent runs
that role; `model` is an alias/model name meaningful to that tool (e.g.
`sonnet`/`opus` for `claude`, `gpt-5.x`-style names for `codex`); `effort` is
`low`/`medium`/`high`/`xhigh`/`max`.

Example `~/.baton/baton.conf`:

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

To override just one project, create `<project>/.baton/config` with
the same `<role>.<key>`/`default.<key>` syntax - it's checked first. Run
`baton config [DIR]` any time to see exactly what a directory would
launch with.

Because every launch is a fresh session (see [Usage](#usage) above), you can
freely change a role's `tool`/`model`/`effort` between a `baton stop` and the
next `baton resume` - there's no per-instance state tying a role to the tool
it last ran under.

### Selecting models

The `start`/`resume` screen never takes a typed model name - each tool's
actual valid model ids change over time and aren't something baton can
discover from a flag, so guessing at free text was a good way to end up with
a role silently misconfigured. Instead, `←`/`→` on the model column cycles
through that role's *tool's* list in `models.json` (next to `baton.conf`;
override the path with `$BATON_MODELS`):

```json
{
  "claude": ["sonnet", "opus", "haiku"],
  "codex": ["gpt-6-sol", "gpt-6.1-sol", "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.5"],
  "omp": ["kimi-k3", "kimi-k2.6", "kimi-k2.7-code"]
}
```

Edit this file to add, remove, or reorder a tool's models (the first entry
is what a role's model snaps to when you switch that role to this tool - see
[Usage](#usage)); baton picks the change up on the next `start`/`resume`, no
reinstall needed. There's no schema beyond "tool name -> array of model id
strings" - whatever a tool's own `--model` flag/config key accepts there is
what belongs in its array. If `models.json` is missing, isn't valid JSON, or
has nothing for a given tool, `←`/`→` on that role's model column is simply
a no-op rather than an error - the role keeps whatever model it already had.

This only curates the *interactive* picker. `baton.conf`/`DIR/.baton/config`
themselves still take any string for `<role>.model` - `resolve_setting`
doesn't check `models.json` - so hand-editing one of those files to a model
id you haven't added there yet still works; it just won't show up as a
cycle-able option in the TUI until you add it.

### Adding a tool

Each tool's actual CLI surface (how it takes a model, an effort/reasoning
level, and a persona) is mapped in `tool_launch_args` and
`tool_needs_typed_persona` in `bin/baton`. `claude`, `codex`, and `omp` are
implemented; wiring up any other `herdr agent start --kind` value baton
doesn't yet know about (see `herdr agent start --help` for the full list) is
a matter of adding a case there once you've confirmed that tool's actual
flags - baton doesn't guess.

### Using z.ai / GLM models

Set a `claude`-tool role's `model` in `baton.conf` to a z.ai model name
(`glm-*`, e.g. `glm-5.3` or `glm-5.3-flash`); `spawn_pipeline_panes` in
`bin/baton` detects that prefix and sets that pane's
`ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` env to z.ai's endpoint and
`$ZAI_API_KEY` itself (the same override the `zai` shell function applies
for interactive use), so plain `claude` in that pane talks to z.ai without
needing the wrapper. Requires `ZAI_API_KEY` to be set wherever you run
`baton start`/`resume` - it exits with an error naming the role if a `glm-*`
role is configured and it isn't.

## Pane layout & readability

By default all 6 role panes are laid out `tiled` - a rough grid, built as a
sequence of binary splits (herdr panes are a BSP tree, not a named grid
layout like tmux's). That's fine on a large monitor, but on a laptop screen
six equal panes leaves each one too small to comfortably read.

Two ways to deal with it:

1. **Zoom the pane you're reading (no config, works today).** herdr's
   built-in pane zoom toggles the focused pane to fullscreen and back. Since
   you usually only read one role at a time (most often the conductor),
   this is the fastest fix and needs nothing changed.

2. **Change the default layout.** Set `layout` in `baton.conf`
   (global or per-project) to one of:

   - `tiled` - equal grid (default)
   - `main-vertical` - conductor gets one large pane on the left; the other
     5 roles sit stacked in a narrower column on the right
   - `main-horizontal` - conductor gets one large pane on top; the other 5
     sit in a shorter row underneath

   The conductor pane is always the "main" pane in these layouts, since
   it's the one you interact with most (giving it the goal, watching
   backlog progress). The other roles mostly just need to be glanced at
   when something needs your attention - pane zoom still works on any of
   them individually.

   This is a tab-level setting, so it isn't per-role - just set
   `layout=...` at the top level of the config file, no role prefix.

## How it works

- `bin/baton` is the CLI: it creates the herdr workspace/tab, splits
  one pane per role (`herdr pane split`), resolves each role's `tool`/
  `model`/`effort` from `baton.conf`, and starts that tool in each pane via
  `herdr agent start <role>-<instance> --kind <tool> --pane <id> -- <tool's
  launch args>`, with `BATON_ROOT`, `BATON_MARKER_DIR`, and `BATON_ROLE` set
  on the pane's environment via `--env`. `tool_launch_args` in `bin/baton`
  maps model/effort/persona onto each tool's actual CLI surface (a real
  system-prompt file flag for `claude`; `-c key=value` config overrides for
  `codex`; for any tool with no system-prompt flag, the persona is instead
  typed in as the pane's first message right after launch - see
  `tool_needs_typed_persona`). Each run's role→agent-name mapping is
  recorded in `$marker_dir/agents.map`.
- `bin/baton-handoff --status done|blocked [--route ROLE] "<payload>"`
  is what a role's prompt runs on completing (or bouncing) a turn. It
  records the handoff durably - a kata comment on the current backlog item
  (the normal, conductor-driven case) or, absent an item to comment on (a
  manually-driven chain with no conductor), a local
  `$BATON_MARKER_DIR/<role>.done`/`<role>.blocked` file - then resolves the
  next role (an explicit `route: <role>` line, or a fixed next-stage table:
  researcher→planner→principal→implementer→reviewer→conductor→researcher)
  and sends the payload straight into that role's pane via `herdr agent
  prompt`. It runs as a plain shell command, so this works the same whether
  the calling pane is `claude`, `codex`, or `omp`. `bin/baton-msg <role>
  "<text>"` is a different, fire-and-forget way for one role to ping another
  pane directly (e.g. the conductor interrupting a stuck implementer)
  without going through the handoff mechanism. It never waits for or
  returns a reply, and never advances the pipeline.
- `hooks/baton-dispatch.sh` is registered globally as a Claude Code Stop
  hook - it no-ops instantly for any session that isn't a baton pane (the
  overwhelming majority on a normal machine), so it's safe to leave
  registered globally, and it's a no-op for any non-Claude pane too (Codex
  and other tools have no equivalent lifecycle hook). For a Claude baton
  pane, it guards against a role finishing a turn on a dispatched backlog
  item without actually calling `baton-handoff` - every role but conductor
  is supposed to end every such turn with a `done` or `blocked` call (see
  each prompt's Completion/bounce sections), and nothing else is watching an
  unattended pane to notice if it doesn't. It tells whether a handoff
  happened by checking the timestamp `baton-handoff` drops in
  `.dispatch-state/` against the last one it already credited; if none
  landed since its last check, it blocks the Stop twice (via
  `hookSpecificOutput.additionalContext`, shown to the role as guidance, not
  an error) reminding it to finish the handoff; if a third turn still ends
  without one, it stops nudging and pings the conductor pane once instead,
  so a human notices the stall rather than the pipeline going silently
  quiet. Scoped to the conductor-driven path only
  (`$BATON_MARKER_DIR/conductor-run` exists) - a manually-driven chain
  already has a human attending the pane.
- `prompts/*.prompt.md` are the six personas, loaded via each tool's own
  system-prompt mechanism (or typed as the pane's first message) for the
  life of that pane.
- The backlog itself - goals and their items - is never written to a file;
  the conductor's prompt persists it as kata issues instead (see
  [Backlog tracking](#backlog-tracking) above).

## Environment variables

| Variable                  | Set by                | Meaning                                        |
|----------------------------|-----------------------|-------------------------------------------------|
| `BATON_ROOT`          | `baton`          | The project directory the run was started for  |
| `BATON_MARKER_DIR`    | `baton`          | This run's `.baton/s/<uuid>/` dir        |
| `BATON_ROLE`          | `baton`          | This pane's role name                          |
| `BATON_PROMPT_DIR`    | you (optional)        | Override where role `.prompt.md` files live    |
| `BATON_CONF`          | you (optional)        | Override the global `baton.conf` path    |
