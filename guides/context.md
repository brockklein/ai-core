# Agent context

Agent context is everything an agent reads that it did not get from the code: `AGENTS.md`, docs, skills, comments written for agents, and tool descriptions. This guide covers `AGENTS.md` and the docs. Skills have [their own guide](skills.md).

## The two costs

Every piece of context spends one of two budgets:

- **Context load.** An always-loaded line, such as a line in `AGENTS.md` or a skill's description, costs tokens and attention on every turn, whether the current task needs it or not.
- **Cognitive load.** Material an agent reaches only through a pointer costs a person something instead: a person has to know it exists and keep its pointer sharp.

The layout below keeps context load low by putting most material behind pointers whose wording says when to reach them. The [writing-for-agents](../starter/.agents/skills/writing-for-agents/SKILL.md) skill explains the levers in depth. Read it before you write any agent context.

## The layout

| File | Loaded | Holds |
| --- | --- | --- |
| `AGENTS.md` | Every session | What every agent needs on every task. |
| `CLAUDE.md` | Every session | One line: `@AGENTS.md`. `AGENTS.md` is the source, so Codex and Claude Code read the same text. |
| `docs/README.md` | Every session, because `AGENTS.md` says to read it | An index. Each entry names the topics its doc covers, so an agent can match its task to the entry without opening the doc. |
| `docs/glossary.md` | Every session, because `AGENTS.md` says to read it | One-line entries for the terms agents get wrong. |
| `docs/internals/*.md` | When the index entry matches the task | Decisions, constraints that span components, and traps the source alone does not explain. |
| `docs/operations/*.md` | When performing the operation | Procedures a person follows: first-time setup, release, restore. |
| `<directory>/AGENTS.md` | When an agent works in that directory | Rules for that directory only, such as "use the existing UI primitives". |
| Comments beside code | When an agent reads that code | Local behavior and the reason for it. |

### What goes in `AGENTS.md`

In this order:

1. **What the project is.** One paragraph: the product, its parts and their stacks, and where a legacy system's behavior can be read.
2. **Reading guidance.** Read the docs index and the glossary.
3. **Architecture.** Only the decisions every agent needs before touching any code: for example, the data paths a feature can take, and how the API contract reaches clients.
4. **The ways to cause problems.** The few actions with real blast radius, each with its safe path. Production is reached only through one command a person runs. Local dev never calls a production third-party API. The shared staging environment is announced before use.
5. **Hit every surface.** The checklist of dimensions a change can silently miss: platforms, layouts, roles, offline, fielded clients that lag the server, reverse states (a way in needs a way out), contracts and codegen, environments, docs. The verifier walks it and reports which entries applied. This list catches more real defects than anything else in the file.
6. **Working locally.** The task runner, the environment command for worktrees, how to query the database, how to run one test, and what `check` runs.
7. **Conventions** an agent would get wrong by copying the nearest file.
8. **Workflow.** The tracker, where finished work lands, commit subjects, context branches, review before commit, verifying live.
9. **Documentation and context.** The ladder and the committed-context rule. See below.
10. **Taste.** Rules of taste a person has settled, one line each. Agents propose additions when a person's input settles a question.

An optional owner's note near the top, in the owner's own voice, can carry the values behind decisions ("fight for the smallest model that makes the correct behavior unsurprising"). Keep it only if it changes how agents choose.

### What stays out of `AGENTS.md`

- First-time setup. It goes in `docs/operations/first-time-setup.md`, reached from the index only when someone sets up a machine.
- Detail only some tasks need, such as auth internals or a legacy migration. It goes in an internals doc.
- Rules for one directory. They go in that directory's `AGENTS.md`.
- Procedures for worktrees and parallel work. They live in the orchestrate skill.
- Descriptions of what a command prints or does. The agent sees that when it runs the command.
- Product, support, and business notes that don't change how code gets written.

## The rules for committed context

These are in the `AGENTS.md` template. They exist because context rots by accumulation: adding feels safe and removing feels risky, so stale layers settle.

- **The ladder.** When something trips an agent up: eliminate it, catch it with a check, flag it for human review, and only then write it down. An agent that reaches the fourth rung says why the first two did not fit. When a fix removes a trap, delete the instruction it made unnecessary.
- **What is true now, and why.** Leave out history, incident stories, dates, the device or version a check ran on, where a fact came from, and whether it has been checked. A version that is a real requirement stays. The issue or pull request holds what happened.
- **Rewrite, don't append.** When a documented decision changes, rewrite or remove the affected text.
- **Point, don't copy.** When the code, a `--help`, or the tracker answers a question, point there. A copy goes stale.
- **One place per fact.** A fact in two places costs maintenance and inflates its importance.
- **Gotchas need evidence.** List only traps agents have hit, and preferably hit more than once.
- **No workflow artifacts.** Specs, progress notes, plans, and decision logs for finished work don't live in the repo. A spec lives on its issue under `## Detail for agents`, with the owner's approval recorded in a comment.

A review angle, **Committed context**, checks every change against these rules. A cross-lab review of context changes catches nothing on these rules unless someone asks it to look.

## Testing what agents read

After you change the layout, start a fresh agent with a minimal prompt, such as "fix the typo in the settings screen", and ask it which context files it opened and why. Do this for a few different tasks. A file every agent opens that no task needs is a cost to cut. A file an agent needed but did not open has a pointer to sharpen.

## Building it for your project

1. Read the code, the scripts, CI, and any existing docs. Note the parts of the system, the commands, and the traps the existing docs warn about.
2. List the terms with more than one meaning or more than one name. Grep for the aliases. Five to ten real entries beat fifty speculative ones.
3. Walk each existing doc. Move it to internals, operations, a directory `AGENTS.md`, a comment beside the code, or the tracker. Delete it if the code already says it.
4. For each warning in the old docs, try the ladder first. Can a script default or a check remove it?
5. Fill `starter/AGENTS.md`. Then delete every sentence that doesn't change what an agent does.
6. Run the read test above.
