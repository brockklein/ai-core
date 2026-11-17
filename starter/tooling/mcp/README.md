# project-db MCP server

[`db-server.mjs`](db-server.mjs) exposes one tool, `psql`, which pipes SQL to `psql` on stdin, so meta-commands like `\dt` and `\d table` work. Both [Claude Code](../../.mcp.json) and [Codex](../../.codex/config.toml) register it as `project-db`. It has no dependencies, so it runs in a fresh worktree before any install.

## What `local` reaches

The default target, `local`, reads this checkout's primary env file on every call, so `node tooling/task-env.mjs up <name>` takes effect without restarting the server.

- **Main checkout:** the database that the env file's database URL names, or another database you name on the same server. A URL that isn't on this machine is refused.
- **Worktree:** only the task database that `up` created, as the env file and the task's lease both name it. Before `up`, after `down`, or in a client-only task, every call is refused. Naming another database and `\connect` are refused too.

Output is capped at 50,000 characters per stream, so use `LIMIT`. Statements are cancelled by Postgres after the timeout in [`db-targets.mjs`](db-targets.mjs), and the server cancels `psql` itself shortly after that.

## Adding a target

Extra targets are off by default. To add one, append an entry to `extraTargets` in [`db-targets.mjs`](db-targets.mjs). That file documents the entry's shape and has a commented example. Every extra target is treated as live: the tool description flags it in capitals, and nothing scopes it to a worktree. Give it a read-only role where you can.

## Testing

[`test/db-server.test.sh`](test/db-server.test.sh) drives the server over stdio with a fake `psql`, so it needs no Postgres.
