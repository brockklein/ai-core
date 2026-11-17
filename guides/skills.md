# Skills

A skill is a folder under `.agents/skills/` with a `SKILL.md` and any supporting files. An agent loads it on demand. `.claude/skills` is a symlink to `.agents/skills`, so Claude Code and Codex read the same files. Keep skills in the repo, not in a user's home folder: a repo copy is reviewed, every harness sees it, and a stale personal copy can't silently override it.

## Two ways to invoke a skill

- **Model-invoked.** The skill's `description` stays in context, so the agent can reach for it on its own, and other skills can name it. Use this when an agent must find the skill without being told. The description is a pointer: front-load the trigger word, and give one trigger per distinct case.
- **User-invoked.** `disable-model-invocation: true` hides the skill from the agent until a person types its name. Use this for heavy procedures that should start only on purpose, such as orchestration. It costs no context, but a person must remember it exists.

For Codex, `agents/openai.yaml` in the skill folder sets the display name and turns off implicit invocation for a user-invoked skill.

[`writing-for-agents/SKILL-MECHANICS.md`](../starter/.agents/skills/writing-for-agents/SKILL-MECHANICS.md) has the details.

## Generic skills: copy unchanged

| Skill | Invoked | What it does |
| --- | --- | --- |
| [writing-for-agents](../starter/.agents/skills/writing-for-agents/SKILL.md) | Model | The craft of agent context: pointers, the two loads, the information hierarchy, completion criteria, leading words, and pruning. Read before writing any skill or `AGENTS.md`. |
| [writing-for-humans](../starter/.agents/skills/writing-for-humans/SKILL.md) | Model | Lead with what the reader needs, then write in Simplified Technical English. Includes the QA handoff shape. Used for commits, issues, pull requests, release notes, and wizard text. |
| [diagnosing-bugs](../starter/.agents/skills/diagnosing-bugs/SKILL.md) | Model | Build a tight, red-capable feedback loop first, then reproduce, minimise, hypothesise, instrument, fix with a regression test, and clean up. |
| [grilling](../starter/.agents/skills/grilling/SKILL.md) | User | Stress-test a plan by working its design tree in rounds, with a recommended answer for each question. |
| [prototype](../starter/.agents/skills/prototype/SKILL.md) | User | Throwaway code that answers one design question: a logic walkthrough in one HTML file, or several UI variants on one route. |
| [wizard](../starter/.agents/skills/wizard/SKILL.md) | Model | Generates an interactive bash wizard for steps only a person can do. See below. |

`writing-for-humans` has one section to fill: the project's QA surfaces.

### Wizard

Some steps only a person can do: clicking through a third-party dashboard, creating an API key, approving a cutover. Re-explaining them to an agent each time is slow, and doing them from memory goes wrong. A wizard is a bash script that walks the person through them. It opens each URL, says exactly what to click and copy, captures each value (hidden for secrets), writes it to `.env` or to a GitHub secret, confirms before anything irreversible, and shows "Stage 3/7".

`starter/tooling/wizards/lib/wizard.sh` provides the user experience. The agent's job is only to scope the procedure and write the stages. Each stage can run on its own (`--only 7`), so a later stage re-reads what an earlier one wrote, or stops and says which stage to run. A risky command runs through `run_cmd`, which shows the exact command and, inside tmux, runs it in a split pane while the wizard waits for its exit code.

Agents run a wizard only with `--help` or `--list`. Wizards are for a person at the keyboard. A wizard can be thrown away after one run, or committed as the repeatable setup path that a runbook links to.

## Template skills: fill for your project

### orchestrate

The coordinator's procedure. It is mostly generic: fill the commands, the environment types, and the shared resources. See [Orchestration](orchestration.md).

### drive-app

How a verifier uses the running product. Make one copy per surface that is driven differently, such as `<app>-web` for a browser and `<app>-mobile` for simulators and emulators, and name each after the app.

What to put in it:

- **Start from the assignment.** The verifier already has an environment and a device. This skill never starts or tears down stacks: that belongs to the orchestrate skill, so the two can't disagree. Keep one line for an agent working without a coordinator.
- **Launch.** The exact commands to serve this surface on this checkout's ports, how to tell it is ready, and what a code change needs to appear (reload, rebuild, relaunch).
- **Open.** The tool recipe: an isolated browser profile in a new tab, or the assigned device.
- **Sign in.** Credentials from the brief, or a command that creates the agent's account. Name what the screen shows once signed in. A sign-in wall means blocked, not passed.
- **Exercise.** A goal, not a script: drive the flows the change touches, try to break them, and confirm writes reached the database.
- **QA an issue.** The black-box pass against acceptance criteria, with VERIFIED, FAILED, and UNVERIFIABLE verdicts and screenshot evidence.
- **Gotchas.** Grouped by phase. Add an entry only after agents hit it more than once. These lists are where most of a drive skill's value grows over time: framework quirks such as dropped clicks during transitions, canvas UIs that need injected pointer events, and simulator traps.

Script no specific UI paths. A scripted sequence must be maintained, and every verifier will repeat it even when the change doesn't touch that flow.

### issue-tracker

How agents work with the tracker. Rename it to the tracker (`linear`, `jira`, `github-issues`).

What to put in it:

- **People.** Owner, QA, and the agents' own account, with ids.
- **Tools.** The tracker MCP server and a small CLI for what the MCP can't do, especially `start <KEY>`. `start` moves the issue, assigns the agent account, and prints the description and every comment, because the comments are part of the brief.
- **Issue shape.** Types, a fixed label set, `ready-for-agent` and `ready-for-human`, and `## Summary` for a person followed by `## Detail for agents`.
- **Statuses.** Which moves automation makes (a push moves an issue to Dev Complete; a deploy moves it to QA), and which a person makes.
- **Working an issue.** Start, commit with the key first, and write the QA comment when the issue reaches a person.
- **Project management**, if agents help run the project: board review, triage, ranking, rollover. Put each procedure in a sibling file behind one pointer line.
- **Changing the setup.** A separate file listing everything that breaks when a status or label is renamed. The owner approves each change.

## Writing more skills

Write a skill when a procedure recurs and an agent can't infer it from the code. Before you write one:

- Try the ladder from [Tools](tools.md). A command may remove the need.
- Give each step a completion criterion the agent can check ("done when `dev:status` shows each stack running").
- Keep the main file short. Move material only some branches need into a sibling file behind a pointer.
- Use leading words that already mean something to the model (*tight*, *red*, *lease*) instead of restating an idea in several places.
- Say what to do, not what to avoid. A prohibition makes the wrong action more available. Keep "do not" for real hazards.
