# claudespace

A tmux-based runner for a 6-role Claude Code pipeline: **conductor →
researcher → planner/principal → implementer → reviewer**. Each role is a
separate `claude` process in its own tmux pane, running with a fixed system
prompt (its "persona") for the life of the pane. A global Claude Code Stop
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

- `tmux`
- the `claude` CLI (Claude Code), on your PATH
- `uuidgen` (ships with macOS and most Linux distros)
- `bash` 3.2+ (the scripts avoid associative arrays for macOS's stock bash)
- `python3` (used only by `install.sh`, to merge the Stop hook into
  `~/.claude/settings.json` without clobbering any other hooks you have)

## Install

```
git clone <this repo> ~/.claudespace
~/.claudespace/install.sh
```

`install.sh` is idempotent - safe to re-run. It:

1. Makes the scripts executable.
2. Warns if `tmux`, `claude`, or `uuidgen` aren't on PATH.
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

A directory can have multiple concurrent runs, each its own tmux
window/session and its own marker dir under `DIR/.claudespace/s/<uuid>/`.
`claudespace start` adds `.claudespace/` to that directory's `.gitignore`
automatically if it's inside a git repo - this is per-project runtime state
(session ids, hand-off markers, dispatch bookkeeping), not something to
commit.

Run `claudespace start`/`resume` from inside an existing tmux client and it
adds a window to your current session; run it from outside tmux and it
creates a dedicated session and attaches. It never nests a session inside
another.

### `--think`

`claudespace start --think DIR` drops a `think` marker file in the run's
marker dir. The role prompts check for it and, when present, spend more
deliberation on each turn (at the cost of speed). Leave it off for routine
runs.

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

By default all 6 role panes are laid out with tmux's `tiled` layout - an
equal grid. That's fine on a large monitor, but on a laptop screen six equal
panes leaves each one too small to comfortably read.

Two ways to deal with it:

1. **Zoom the pane you're reading (no config, works today).** tmux's
   built-in `prefix + z` toggles the focused pane to fullscreen and back.
   Since you usually only read one role at a time (most often the
   conductor), this is the fastest fix and needs nothing changed.

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
   when something needs your attention - `prefix + z` still works on any
   of them individually.

   This is a tmux window-level setting, so it isn't per-role - just set
   `layout=...` at the top level of the config file, no role prefix.

## How it works

- `bin/claudespace` is the CLI: it creates the tmux window, splits one pane
  per role, and launches `claude --model ... --effort ... --append-system-prompt "$(cat prompts/<role>.prompt.md)"`
  in each, exporting `CLAUDESPACE_ROOT`, `CLAUDESPACE_MARKER_DIR`, and
  `CLAUDESPACE_ROLE` into the pane's environment.
- `hooks/claudespace-dispatch.sh` is registered globally as a Stop hook. It
  no-ops instantly for any Claude Code session that isn't a claudespace pane
  (which is the overwhelming majority on a normal machine), so it's safe to
  leave registered globally. For a claudespace pane, it watches for
  `$CLAUDESPACE_MARKER_DIR/<role>.done` or `<role>.blocked`, written by the
  role's prompt when it finishes a turn of work. It resolves the next role
  (an explicit `route: <role>` first line in the marker, or a fixed
  next-stage table: researcher→planner→principal→implementer→reviewer→conductor→researcher),
  and types the marker's payload into that role's pane.
- `bin/claudespace-msg <role> "<text>"` is a fire-and-forget way for one
  role to ping another pane directly (e.g. the conductor interrupting a
  stuck implementer) without going through the marker/Stop-hook hand-off.
  It never waits for or returns a reply.
- `prompts/*.prompt.md` are the six personas, loaded as each pane's
  `--append-system-prompt` for the life of that pane.

## Environment variables

| Variable                  | Set by                | Meaning                                        |
|----------------------------|-----------------------|-------------------------------------------------|
| `CLAUDESPACE_ROOT`          | `claudespace`          | The project directory the run was started for  |
| `CLAUDESPACE_MARKER_DIR`    | `claudespace`          | This run's `.claudespace/s/<uuid>/` dir        |
| `CLAUDESPACE_ROLE`          | `claudespace`          | This pane's role name                          |
| `CLAUDESPACE_PROMPT_DIR`    | you (optional)        | Override where role `.prompt.md` files live    |
| `CLAUDESPACE_CONF`          | you (optional)        | Override the global `claudespace.conf` path    |
