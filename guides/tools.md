# Tools for agents

An instruction asks an agent to remember. A tool removes the need to remember. Where a tool can do the job, use it instead of an instruction.

## The ladder

When an agent stumbles, take the first rung that works:

1. **Eliminate it.** Change the code, the data shape, the script, or the default so the mistake can't happen. *Example:* rather than telling agents "run `task-db create` before a schema change", make the app refuse every database command in a worktree until `task up` has given it a database.
2. **Catch it** with a test, a lint rule, a CI check, or a command that refuses the wrong move. *Example:* a pre-push hook that refuses context changes on the integration branch.
3. **Flag it for human review**, when it needs judgment no check can express.
4. **Write it down**, as a comment beside the trap, a skill step, or a line in `AGENTS.md`, and say why rungs 1 and 2 did not fit.

## Principles

**Refuse to guess.** A script that can't tell what it should act on stops and says what it needs. A port script with no port configured, a database script facing a non-local host, and a deploy from a dirty tree all stop. These refusals protect other agents, other projects on the same machine, and production.

**A refusal names the fix.** Every refusal prints the command that gets past it, and the deliberate bypass if one exists. An agent that hits a refusal can then recover without a person.

**Status commands only read.** `dev:status` reports and always exits 0. The coordinator uses it to check "done when" lines without risk.

**Names match purposes.** A script is named for what it does, so its name works as a pointer.

**One command per intent.** Collapse multistep procedures: `task up`, `task down`, `check`, `main:update`. The skill then names one command instead of five steps, and the steps can't be done out of order.

**Prefer one fixed setting to options.** Every switch is a branch that agents can get wrong. When a per-worktree switch appears, ask whether a single fixed behavior would do. For example, outside services can always be off in worktrees.

**Automate bookkeeping that a machine can see.** Status moves in the tracker, labels from changed paths, and deploy tracking all belong in CI or hooks, not in agent instructions. Don't build recovery machinery for automation failures in advance. If a move fails, someone notices, and the cause gets fixed.

**Self-test the tools.** Each guard has a self-test, so a change to a guard can't silently disable it.

## What's in `starter/tooling/`

| Tool | What it does |
| --- | --- |
| `worktree-setup.sh` | Runs when the harness creates a worktree. It copies gitignored local config from the main checkout, never release material, and installs dependencies. |
| `task-env.mjs` + `task-env.config.mjs` | The environment manager. See [Environments](environments.md). |
| `dev-status.mjs` | Read-only report of this checkout's services, ports, and task, naming any other process that holds a port. |
| `hooks/pre-push` | Refuses updates to protected branches, refuses context on the integration branch, refuses branches that mix context and code, checks commit subjects, and runs the project's check before an integration push. |
| `hooks/commit-msg` | Checks the commit subject. |
| `check-commit-subjects.sh` | Subjects are `<KEY>: <subject>` or `<area>: <subject>`, so the tracker automation can read them. |
| `check-markdown-links.mjs` | Fails on broken relative links in Markdown. |
| `check-mcp-parity.mjs` | `.mcp.json` (Claude Code) and `.codex/config.toml` (Codex) must declare the same servers and transports. |
| `repo.conf` | The branch names, issue key, and context paths that the hooks and checks share. |
| `wizards/lib/wizard.sh` | The wizard library. See [Skills](skills.md#wizard). |

### Guardrails beyond hooks

- **Harness permissions.** `starter/.claude/settings.json` denies the common spellings of a push to the protected branch and of `--mirror`, and asks before a production promotion. These rules add to the git hook and to server-side branch protection, and replace neither: a bare `git push` names no branch, and Codex has no deny rules. They leave `--no-verify` allowed, so a person can bypass the hooks on purpose. Server-side branch protection is the backstop.
- **Hooks are scripts, not lefthook commands.** Lefthook silently skips a pre-push *command* when HEAD has no diff against its upstream, so `git push origin <sha>:main` would pass. The pre-push hook runs as a script for that reason.
- **Check at the moment of risk.** The pre-push hook runs the full check before a push to the integration branch. Running CI only at promotion, not on every push, is one option if CI minutes are scarce. The local gate then carries the load, so keep it strict and fast.

## MCP servers

Give agents MCP servers for the systems they touch most:

- **The tracker**, so agents read and write issues directly. Log it in as the agents' own account.
- **The database**, scoped to the current checkout. A worktree reaches only its own task database and refuses without one. This prevents both credential handling and queries against the wrong database. Cap its output so a `select *` can't flood an agent's context. Build it without dependencies, so it runs in a fresh worktree before an install.

Declare each server in both `.mcp.json` and `.codex/config.toml`, and let `check-mcp-parity.mjs` keep them in step.

## Accounts for agents

- **A tracker account for agents.** Moves and comments are then visibly an agent's, and its permissions can differ from a person's.
- **A test login a command creates.** A command such as `agent-admin` makes sure the account exists and repairs it, so no person hands an agent a password. It changes only accounts it created.
- **Leased fixtures.** On a shared database, test accounts are leased to one attempt at a time. See [Environments](environments.md).

## Building it for your project

1. Read the git history and old docs for warnings and rules. Each is a candidate for rung 1 or 2.
2. Fill `starter/tooling/repo.conf`: protected branch, integration branch, issue key, context paths, and the check command.
3. Wire the hooks into the project's hook manager, or use `git config core.hooksPath tooling/hooks`, and install them in the main checkout only.
4. Add the checks to `check` and to CI.
5. Write a `check` command if the project lacks one. It runs what a change needs, against the integration branch, in one command.
6. Port the database MCP server pattern if the project has a database.
