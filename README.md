# claudespace

A [herdr](https://herdr.dev/)-based runner for a 6-role Claude Code pipeline:
**conductor → researcher → planner/principal → implementer → reviewer**. Each
role is a separate `claude` process in its own herdr pane, running with a
fixed system prompt (its "persona") for the life of the pane. A global Claude
Code Stop
hook watches for hand-off marker files and types the next role's input into
its pane automatically, so a run can go from a one-line goal to a reviewed
backlog of shipped changes largely unattended.

```
you: claudespace start ~/code/my-project
     -> give the conductor pane a goal
conductor -> researcher -> planner -> principal -> implementer -> reviewer -> conductor -> ...
             (loops per backlog item until the backlog is exhausted, blocked, or capped)
```

## Requirements

- [`herdr`](https://herdr.dev/) (`herdr status` should show `server: running`)
- the `claude` CLI (Claude Code), on your PATH
- [`kata`](https://github.com/kenn-io/kata) - the conductor persists the
  backlog as kata issues (see [Backlog tracking](#backlog-tracking) below)
  rather than a markdown file; run `kata init` once in a project before its
  first `claudespace start` (the conductor also does this itself if it
  hasn't been done yet)
- `uuidgen` (ships with macOS and most Linux distros)
- `bash` 3.2+ (the scripts avoid associative arrays for macOS's stock bash)
- `python3` - used by `install.sh` to merge the Stop hook into
  `~/.claude/settings.json` without clobbering any other hooks you have, and
  by `bin/claudespace` itself to parse herdr's JSON responses and to mark a
  project trusted in `~/.claude.json` before launching its panes

## Install

```
git clone <this repo> ~/.claudespace
~/.claudespace/install.sh
```

`install.sh` is idempotent - safe to re-run. It:

1. Makes the scripts executable.
2. Warns if `herdr`, `claude`, or `uuidgen` aren't on PATH.
3. Appends `export PATH="$HOME/.claudespace/bin:$PATH"` to your `~/.zshrc` or
   `~/.bashrc` (whichever matches `$SHELL`), if that line isn't already
   there.
4. Registers `~/.claudespace/hooks/claudespace-dispatch.sh` as a global Stop
   hook in `~/.claude/settings.json`, if it isn't already registered. This
   only adds an entry to the `Stop` hook list - it doesn't touch any other
   hooks you have configured.

If your shell isn't zsh or bash, or you'd rather do it by hand, the two
things `install.sh` does for you are:

```sh
# in your shell rc
export PATH="$HOME/.claudespace/bin:$PATH"
```

```jsonc
// in ~/.claude/settings.json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.claudespace/hooks/claudespace-dispatch.sh", "timeout": 10 }
        ]
      }
    ]
  }
}
```

Open a new shell after installing, then run `claudespace start` inside any
project directory.

## Usage

```
claudespace start [--think] [DIR]   Start a new instance for DIR (default: cwd)
claudespace status [DIR]            List every instance for DIR, running or stopped
claudespace attach [REF] [DIR]      Switch into a running instance (REF: slug or uuid)
claudespace resume [REF] [DIR]      Reconnect a stopped instance's panes to their saved sessions
claudespace stop [REF] [DIR]        Kill a running instance
claudespace config [DIR]            Show each role's resolved model/effort/layout for DIR
```

`REF` is optional whenever `DIR` has exactly one instance. A "run" gets a
short uuid; once its conductor persists a backlog, the run also gets a
`slug` (the backlog's own slug) so you can address it by name instead of by
uuid.

A directory can have multiple concurrent runs, each its own herdr
workspace/tab and its own marker dir under `DIR/.claudespace/s/<uuid>/`.
`claudespace start` adds `.claudespace/` to that directory's `.gitignore`
automatically if it's inside a git repo - this is per-project runtime state
(session ids, hand-off markers, dispatch bookkeeping), not something to
commit.

Run `claudespace start`/`resume` from inside an existing herdr pane and it
adds a tab to your current workspace; run it from outside herdr and it
creates a dedicated workspace. Either way, `claudespace stop` only ever
closes what that run itself created - a tab it added to your workspace, or
a workspace it created outright - never the rest of your panes.

### `--think`

`claudespace start --think DIR` drops a `think` marker file in the run's
marker dir. The role prompts check for it and, when present, spend more
deliberation on each turn (at the cost of speed). Leave it off for routine
runs.

### Trust

`claudespace start`/`resume` mark `DIR` as trusted in `~/.claude.json`
(the same field Claude Code itself sets when you answer "Yes, I trust this
folder") before launching any panes. Naming `DIR` to `claudespace` already is
that trust decision - without this, all 6 panes would otherwise stall on that
dialog with no one watching to answer it, since herdr's `agent start` (unlike
a blind tmux `send-keys`) actually waits for the launched `claude` to become
interactive-ready.

### Backlog tracking

The conductor decomposes a goal into a backlog and drives the pipeline
through it, same as always - but the backlog itself lives in
[kata](https://github.com/kenn-io/kata), not a `docs/backlog-<slug>.md`
file. Each goal becomes one kata issue (labeled `claudespace-backlog`); each
backlog item becomes a child kata issue (labeled `backlog-<slug>`), linked
to the items it depends on via kata's `--blocked-by` relationship instead of
a hand-rolled `requires:` field. Item status is just kata issue state - open
and unowned is pending, claimed is in-progress, closed is done, and an open
item kata's own dependency graph won't surface yet (via `kata ready`/`kata
next`) is blocked. The conductor is still the only role that ever claims,
closes, or edits a backlog item; `kata list --label backlog-<slug> --agent`
in the project directory shows you the same thing `claudespace status`
already summarizes per run.

## Configuration

Per-role `model`/`effort`, plus the window `layout` (see [Pane layout &
readability](#pane-layout--readability) below), come from a `claudespace.conf`
file, with project-level settings winning over global ones:

```
<project>/.claudespace/config   ->  <role>.<key>       (most specific)
<project>/.claudespace/config   ->  default.<key>
~/.claudespace/claudespace.conf ->  <role>.<key>        ($CLAUDESPACE_CONF overrides the path)
~/.claudespace/claudespace.conf ->  default.<key>
built-in fallback               ->  model=sonnet, effort=high, layout=tiled
```

Roles: `conductor`, `researcher`, `planner`, `principal`, `implementer`,
`reviewer`. `model` is an alias (`sonnet`, `opus`, `fable`) or a full model
name; `effort` is `low`/`medium`/`high`/`xhigh`/`max`.

Example `~/.claudespace/claudespace.conf`:

```
default.model=sonnet
default.effort=high

conductor.effort=medium
implementer.effort=medium

layout=tiled
```

To override just one project, create `<project>/.claudespace/config` with
the same `<role>.<key>`/`default.<key>` syntax - it's checked first. Run
`claudespace config [DIR]` any time to see exactly what a directory would
launch with.

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

2. **Change the default layout.** Set `layout` in `claudespace.conf`
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

- `bin/claudespace` is the CLI: it creates the herdr workspace/tab, splits
  one pane per role (`herdr pane split`), and starts `claude` in each via
  `herdr agent start <role>-<instance> --kind claude --pane <id> -- --model
  ... --effort ... --append-system-prompt-file prompts/<role>.prompt.md`,
  with `CLAUDESPACE_ROOT`, `CLAUDESPACE_MARKER_DIR`, and `CLAUDESPACE_ROLE`
  set on the pane's environment via `--env`. Each run's role→agent-name
  mapping is recorded in `$marker_dir/agents.map`.
- `hooks/claudespace-dispatch.sh` is registered globally as a Stop hook. It
  no-ops instantly for any Claude Code session that isn't a claudespace pane
  (which is the overwhelming majority on a normal machine), so it's safe to
  leave registered globally. For a claudespace pane, it watches for
  `$CLAUDESPACE_MARKER_DIR/<role>.done` or `<role>.blocked`, written by the
  role's prompt when it finishes a turn of work. It resolves the next role
  (an explicit `route: <role>` first line in the marker, or a fixed
  next-stage table: researcher→planner→principal→implementer→reviewer→conductor→researcher),
  and sends the marker's payload into that role's pane via `herdr agent prompt`.
- `bin/claudespace-msg <role> "<text>"` is a fire-and-forget way for one
  role to ping another pane directly (e.g. the conductor interrupting a
  stuck implementer) without going through the marker/Stop-hook hand-off.
  It never waits for or returns a reply.
- `prompts/*.prompt.md` are the six personas, loaded as each pane's
  `--append-system-prompt-file` for the life of that pane.
- The backlog itself - goals and their items - is never written to a file;
  the conductor's prompt persists it as kata issues instead (see
  [Backlog tracking](#backlog-tracking) above).

## Environment variables

| Variable                  | Set by                | Meaning                                        |
|----------------------------|-----------------------|-------------------------------------------------|
| `CLAUDESPACE_ROOT`          | `claudespace`          | The project directory the run was started for  |
| `CLAUDESPACE_MARKER_DIR`    | `claudespace`          | This run's `.claudespace/s/<uuid>/` dir        |
| `CLAUDESPACE_ROLE`          | `claudespace`          | This pane's role name                          |
| `CLAUDESPACE_PROMPT_DIR`    | you (optional)        | Override where role `.prompt.md` files live    |
| `CLAUDESPACE_CONF`          | you (optional)        | Override the global `claudespace.conf` path    |
