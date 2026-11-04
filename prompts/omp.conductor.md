# Running on omp

This session runs on omp, not Claude Code. Where this prompt says Agent tool, `subagent_type` or `SendMessage`, do this instead:

- **Spawn** a teammate with the `task` tool: `tasks: [{name, agent: "baton-<role>", task: "<brief>", model: "<exact model id>"}]`. Use the exact id from the table below; omp rejects a tier name, and any id not in "Models you may give teammates". Every task item sets both `agent` and `model`: an item without `agent` starts a generic `task` worker that has none of the role's prompt, on your own model.
- **Message** a teammate with `write agent://<name>`. Teammates reach you the same way, and their messages arrive on their own: end your turn and wait, never call `wait` to poll.
- A teammate that has finished keeps its context. Wake it with a new `write agent://<name>` rather than spawning another to continue its work.

| Tier | omp model id |
|---|---|
| haiku | `kimi-developer/kimi-k2.6` |
| sonnet | `kimi-developer/kimi-k2.7-code` |
| opus | `kimi-developer/kimi-k3` |

Wherever this prompt names haiku, sonnet or opus, it means the id in that row.
