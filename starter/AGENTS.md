<!-- FILL: This is the template for the always-loaded agent context. Every line here costs context on every turn, so each one must change what every agent does. A line only some tasks need belongs in a doc behind docs/README.md, or in a directory's own AGENTS.md. Read the writing-for-agents skill before you fill it. Replace every FILL marker; delete a section only when the project truly has nothing for it. Keep the section order: what the project is, reading guidance, architecture, ways to cause problems, hit every surface, working locally, conventions, workflow, documentation and context, taste. Remove these FILL comments as you go. -->

# [[FILL: project name]]

[[FILL: One paragraph. What the product is and who it serves, the major parts and the stack of each (one clause per part), and who owns the project. If it replaces a legacy system, say where that system's behavior can be read.]]

Read [`docs/README.md`](docs/README.md) at the start of each session and follow its reading guidance for your task.

Read [`docs/glossary.md`](docs/glossary.md) at the start of each session.

<!-- FILL (optional): A short note from the owner, in their own voice, on the values behind decisions, e.g. "I like simple systems. Do not preserve complexity because it exists. Fight scope creep." Keep it only if it changes how agents choose between options. Product non-negotiables (what users must always be able to rely on) can go here too. -->

## Architecture

<!-- FILL: Only the decisions every agent needs before touching any code, each as a bold lead-in and a few sentences: the data paths and which one a feature takes, and the API contract and how it reaches clients. Leave out what the code shows at a glance. Detail that only some tasks need (auth internals, a legacy migration) goes in a docs/internals/ file behind its index entry. Rules for one directory (e.g. "use the existing UI primitives; never hand-roll a dialog") go in that directory's own AGENTS.md, which agents load only when they work there. -->

## The ways to cause problems

<!-- FILL: The few actions with real blast radius, numbered, each with the safe path. Typical entries: -->

1. **Production.** Production is reached only through `[[FILL: the promotion command]]`, which only [[FILL: owner]] runs. When work is ready for production, name the sha. Anything else that must happen on production is a handoff: name the exact command, its target, and how to verify the result, then stop.
2. **Third-party APIs.** Local dev never calls a production third-party API. Stub it with a base-URL override, such as `[[FILL: example env var]]`.
3. **[[FILL: shared test environment, e.g. Staging]].** It is shared. Say so before you test there or change its data.
4. **Wizards.** Scripts in `tooling/wizards/` are for a person at the keyboard. Run them only with `--help` or `--list`.

## Hit every surface

The most common defect is a change that works on the path you tested and is missing somewhere else. Before calling work done, walk this list and say which entries applied:

<!-- FILL: One entry per dimension a change can silently miss. Keep the generic ones that apply and make each concrete for this project: -->

- **Platforms.** [[FILL: e.g. iOS and Android differ in dialogs, deep links, purchases. Test the one you didn't build on.]]
- **Layouts and clients.** [[FILL: e.g. desktop vs mobile layout, web vs native, admin console.]]
- **Roles and permissions.** [[FILL: e.g. a new table needs a grant for each role; a gated feature behaves differently per plan.]]
- **Offline, sync, and realtime.** [[FILL: or delete.]]
- **Fielded clients.** Installed builds lag the server, so keep contracts compatible with previous client builds, and deploy server support before a client build that needs it.
- **Reverse states.** If you added a way in, add the way out and the way to see it.
- **Contracts.** A schema or route change reaches clients through `[[FILL: codegen command]]`. Commit its output.
- **Environments.** Local, [[FILL: staging]], and production differ in endpoints, keys, and data.
- **Docs.** Check whether the change makes existing guidance inaccurate.

## Working locally

- [[FILL: the task runner and how to list its tasks (e.g. "`mise tasks` lists them with their usage"). ]]
- In a worktree, run `[[FILL: task runner]] task -- up <name>` before anything touches a database: it gives the worktree its own ports, database copy, and services. `[[FILL: task runner]] dev:status` shows what runs where.
- [[FILL: how to query the local database (ideally an MCP tool scoped to this checkout's database).]]
- [[FILL: how to run one test, per language.]]
- `[[FILL: task runner]] check` runs the checks a change needs. [[FILL: list the guards it runs beyond lint, types, and tests, so agents know a red check can come from them.]]

## Conventions

<!-- FILL: Formatting and lint tools and the command that runs them, dependency-version policy, pinned versions that must stay pinned and why. Only what an agent would get wrong by matching the nearest file. -->

## Workflow

- **Track work in [[FILL: tracker and project key]]**, through the [[FILL: tracker]] skill. Start an issue with `[[FILL: task runner]] tracker -- start <KEY>`, and read every comment: the comments are part of the brief. When you mention an issue to [[FILL: owner]], link it and give its title.
- **Commit and push finished work straight to `[[FILL: integration branch]]`.** Use a branch only for a staged series. The pre-push hook checks commit subjects and runs `[[FILL: task runner]] check` on a push to `[[FILL: integration branch]]`, and refuses the push when a check fails, so run the check before you commit.
- **Commit subjects are `<KEY>: <subject>` or `<area>: <subject>`**, with a lowercase area. Only a `<KEY>:` subject moves its issue.
- **Context changes go on their own `context/<topic>` branch**, as a pull request against `[[FILL: integration branch]]` for [[FILL: owner]] to review. Context is any `*.md` file and anything under `.agents/`, `.claude/`, or `.codex/`. Code that depends on a context change waits until that PR merges, then rebases and lands.
- **Before committing a change you made outside the orchestrate skill**, use `delegate_task` for an adversarial review by a model from the other lab: OpenAI reviews Anthropic-written changes, and Anthropic reviews OpenAI-written changes. Choose the angles from the change's scope. Resolve or answer every finding before committing.
- **Verify a change live** with the [[FILL: drive skill per surface]] skill.
- [[FILL: promotion to the shared test environment, and what else ships with it (e.g. a mobile test build).]]

## Documentation and context

Most code changes need no documentation change. Agents can read the code.

When something trips you up, prevent the recurrence before you move on. Use the first rung that works, and when you reach rung 4, say in the PR or handoff why rungs 1 and 2 did not fit:

1. **Eliminate it.** Change the code, data shape, script, or default so the mistake can't happen.
2. **Catch it** with a test, lint rule, CI check, or a command that refuses the wrong move.
3. **Flag it for human review** in the PR, when it needs judgment no check can express.
4. Only then **write it down** where the next agent will hit it: a comment beside the trap, a skill step, a line here, or a doc. List only gotchas agents have hit.

- When a fix removes a trap, delete the instructions it made unnecessary.
- Explain local behavior in a comment beside the code. Write a doc only for a decision or trap that spans components (`docs/internals/`), or for a procedure a person follows (`docs/operations/`).
- New features are spec-first. The contract goes in the issue's description under `## Detail for agents`, and [[FILL: owner]] approves it there before any code.
- When a documented decision changes, rewrite or remove the affected text instead of appending to it.
- Committed context holds what is true now and why; the issue or PR holds what happened. Leave out history, incident stories, dates, the device or version a check ran on, where a fact came from, and whether it has been checked. A version that is a real requirement stays. When the code, a `--help`, or the tracker answers a question, point there instead of copying the answer.

## Taste

<!-- FILL: Rules of taste a person has settled, one line each, e.g. "Match the surrounding file, except that new code uses `type` over `interface`." Start empty if there are none yet. -->

- If a rule here fights the task in front of you, say so and get a human sign-off before breaking it.

When a person's input settles a question of taste, propose it for this section.
