<img src="assets/icon.svg" width="64" height="64" alt="">

# Agent-ready project starter

*A recipe for setting up a codebase so AI coding agents can do real work in it, several at a time, without stepping on each other.*

## In short

This repo packages an approach that was built and refined across two production projects: a web and mobile product, and a cross-platform app with a sync backend. One agent coordinates, and other agents plan, write, review, and test the work. Each agent runs in its own isolated environment, so many changes can move forward in parallel on one machine.

The approach has five parts:

1. **Agent context.** A short `AGENTS.md` that every agent reads, and docs that agents read only when their task needs them.
2. **Tools for agents.** Commands, hooks, and checks that make the wrong move impossible or loud. A tool beats an instruction.
3. **Environments for parallel work.** One command gives a git worktree its own ports, its own database copy, and its own services. Another command removes all of it.
4. **Skills.** Reusable procedures that agents load on demand: writing, debugging, prototyping, human-run wizards, driving the running app, and working with the issue tracker.
5. **Orchestration.** A coordinator moves each change through plan, implement, review by a model from another AI lab, verification in the running app, landing, and teardown.

Behind all five sits one rule, applied every time an agent stumbles: **eliminate the problem, then catch it with a check, then flag it for a person, and only as a last resort write it down.**

`starter/` holds the files. Point your agent at this repo and ask it to set up your project. [ADOPTING.md](ADOPTING.md) is its procedure.

## What's in the box

| Path | What it is |
| --- | --- |
| [`ADOPTING.md`](ADOPTING.md) | The step-by-step procedure an agent follows to set up another project. |
| [`guides/`](guides/) | The reasoning behind each part, and how to build it for a different stack. |
| [`starter/AGENTS.md`](starter/AGENTS.md) | The always-loaded context template. |
| [`starter/docs/`](starter/docs/) | The docs index, glossary, and first-time setup runbook templates. |
| [`starter/.agents/skills/`](starter/.agents/skills/) | Six generic skills to copy unchanged, and three templates to fill. |
| [`starter/tooling/`](starter/tooling/) | Working scripts: the worktree environment manager, a status command, git hooks, Markdown and config checks, and the wizard library. |
| [`starter/.claude/`, `.codex/`, `.mcp.json`](starter/) | Harness config: the skills symlink, permission guardrails, and the MCP servers both harnesses share. |
| [`scripts/check-fill-markers.sh`](scripts/check-fill-markers.sh) | Lists every placeholder still unfilled. The adoption is done when it lists none. |

Every project-specific spot in `starter/` carries a `FILL:` marker: `<!-- FILL: ... -->` for an instruction, `[[FILL: ...]]` inline, and `# FILL:` or `// FILL:` in code.

## The principles

### Context

**Every line of always-loaded context costs attention on every turn.** `AGENTS.md` holds only what every agent needs on every task: what the project is, the few ways to cause real damage, the checklist of surfaces a change can miss, how to work locally, and the workflow. The rest sits behind a pointer. The docs index says when to read each doc, and a directory's own `AGENTS.md` holds the rules for that directory.

**Test what agents actually read.** Start an agent with a minimal prompt and ask it which files it opened. A doc that every agent loads but no task needs costs context and buys nothing.

**Committed context holds what is true now, and why.** History, incident stories, dates, versions a check ran on, and "this was verified" belong in the issue or the pull request. When a decision changes, rewrite the text. Do not append to it. When the code, a `--help`, or the tracker can answer a question, point there instead of copying the answer.

**Most code changes need no documentation.** Agents can read code. Write a doc only for a decision or trap that spans components, or for a procedure a person follows. Put local behavior in a comment beside the code.

**People review changes to agent context.** Code lands after review by other agents and verification. Changes to `AGENTS.md`, skills, and docs go on their own `context/<topic>` branch as a pull request for a person, because they change how every later agent behaves. A git hook enforces this.

**Specs live on the ticket.** A feature's contract goes in the issue under `## Detail for agents`, and a person approves it there before any code. The repo keeps no specs, progress notes, or decision logs for finished work.

### Tools

**A tool beats an instruction.** When an agent stumbles, work down this ladder:

1. **Eliminate it.** Change the code, the data shape, the script, or the default so the mistake can't happen.
2. **Catch it** with a test, a lint rule, a CI check, or a command that refuses the wrong move.
3. **Flag it for human review**, when it needs judgment no check can express.
4. Only then **write it down**, where the next agent will hit it, and say why the first two rungs did not fit.

When a fix removes a trap, delete the instruction it made unnecessary.

**Scripts refuse to guess.** A port script with no port configured stops. A database script that sees a remote host stops. A deploy refuses a dirty tree. Each refusal protects another agent, another project on the same machine, or production.

**Status commands only read.** The coordinator checks every "done when" line with a command that changes nothing.

**Automate bookkeeping that a machine can see.** A push moves its issue to Dev Complete. A deploy moves it to QA. Agents don't spend tokens remembering to do it, and the status stays true.

**Give agents their own accounts and scoped tools.** Agents get a tracker account and a test login that a command creates, so no person hands an agent a password. A database MCP tool reaches only the current checkout's database.

### Environments

**Isolate everything one agent can break for another.** Each writing agent gets its own worktree, ports, and, when it needs one, a copy of the database. The most useful single artifact in this approach is the list of **shared resources**: everything on the machine that two agents can fight over, with a rule for each. Write it first for any project.

**Make isolation one command, and make the unsafe default impossible.** `task up <name>` gives a worktree its own stack and can be rerun. `task down <name>` removes everything and fails, listing leftovers, if anything remains. Until `up` has run, the app refuses to touch a database from a worktree, so no agent can migrate the main database by accident.

**Allocate by what verification does, not by which files changed.** Separate ports don't isolate rows. A verifier that reseeds fixtures deletes data that another attempt is testing. Client-only work can share the main backend only when its verification is read-only or uses accounts leased to it alone.

**Prefer one fixed setting to per-worktree switches.** Outside services are always off in worktree stacks. A feature that needs a real one is verified on the main stack or in staging.

**Leave the machine as you found it.** Other projects run on the same machine. Stop only what you started. Teardown is a real step with a check.

### Skills

**Copy skills that are generic. Write the project-specific ones from a template.** Six skills here apply to any project: writing for agents, writing for humans, diagnosing bugs, grilling a plan, prototyping, and building human-run wizards. Three are templates: orchestration, driving the running app, and the issue tracker.

**Domain skills start from an assignment.** A skill that drives the app assumes an environment and a device were already handed out. Orchestration steps live only in the orchestrate skill, so the two never disagree.

**Give goals, not scripts.** "Drive the flows your change touches, and confirm the row reached your database" beats a scripted tap sequence that someone must maintain and every verifier will repeat.

**Gotcha lists grow only from repeated stumbles.** An entry earns its place when agents hit it more than once. A fix in code removes the entry.

**Keep skills in the repo, not in a user's home folder.** A repo copy is reviewed, every harness sees it, and it can't silently override the team's version. `.claude/skills` is a symlink to `.agents/skills`, so Claude Code and Codex read the same files.

### Orchestration

**The coordinator writes no code.** It plans units of work, prepares environments, briefs subagents, judges their decisions, lands the work, and tears down. A coordinator that writes code loses track of the plan.

**The other lab reviews.** A model from a different AI lab is less likely to share the blind spots of the model that wrote the code. Strong models review from at least three angles: Standards, Spec, and Committed context.

**Review and verification are different checks.** A review reads the code. A verifier uses the product in a browser or on a simulator and tries to break it. It walks the project's "hit every surface" checklist. A sign-in wall means blocked, not passed.

**Every edit goes through every check.** A fix from verification goes back through review, then verification again.

**Every loop has a limit and a way out.** After three rounds of review or verification, the agents stop and report, and the coordinator decides or asks a person.

**One attempt by default.** Use two or three only where a real design choice is open or the change is risky, such as a migration. Each attempt is a slice of Swiss cheese: every slice has holes, but they fall in different places. A strong model then writes a synthesis plan, and review sees only the combined change.

**Agents talk directly, inside limits the coordinator sets.** Reviewers send findings straight to the implementer. Any agent can ask the coordinator a question and wait. Agents report environment conflicts and do not fix them.

## Choosing a harness

We recommend [T3 Code](https://t3.codes) as the harness. It dispatches agents across AI labs, gives each one its own worktree, lets agents message each other, and drives browsers, iOS Simulators, and Android Emulators. The orchestrate skill names its tools. [guides/harness.md](guides/harness.md) maps each capability to other harnesses.

## Guides

- [Agent context](guides/context.md): `AGENTS.md`, the docs layout, the glossary, and the rules for committed context.
- [Tools for agents](guides/tools.md): the ladder, guardrails, hooks, checks, MCP servers, and wizards.
- [Environments for parallel work](guides/environments.md): worktrees, the environment manager, and the shared-resources list.
- [Skills](guides/skills.md): what each skill does, and how to fill the templates.
- [Orchestration](guides/orchestration.md): the roles, the seven steps, and what we learned running them.
- [The harness](guides/harness.md): why T3 Code, and how to use another harness.

## Adopting it

Ask your agent: *"Read `<path to this repo>/AGENTS.md` and set up this project to follow it."* The agent surveys your repo, copies `starter/`, fills in the markers from what it finds, asks you only for decisions, and opens a pull request. Expect to review that pull request closely. It changes how every later agent behaves in your project.
