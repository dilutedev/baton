# Two Claude Accounts

Add per-role Claude Code profile selection so Baton can run two equal-plan accounts concurrently.

## Account assignment

- Default profile: conductor, researcher, planner
- Secondary profile: principal, implementer, reviewer

This keeps three concurrent panes on each account and does not require related roles to share an account.

## Implementation

- Add a per-role `config_dir` setting to `baton.conf`.
- Pass the configured directory to each pane as `CLAUDE_CONFIG_DIR` when Baton launches it.
- Log in once to the secondary profile before starting a run.
- Ensure each profile's Claude Code settings registers Baton's Stop hook so cross-account handoffs continue to dispatch.

## Example configuration

```ini
principal.config_dir=~/.claude-secondary
implementer.config_dir=~/.claude-secondary
reviewer.config_dir=~/.claude-secondary
```
