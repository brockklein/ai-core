---
name: issue-tracker
description: [[FILL: "Working in the <tracker> project <KEY>. Use when starting a <KEY> issue, committing its work, writing its QA comment, filing or commenting on an issue, triaging or ranking work, or changing how the tracker is set up." Keep only the branches this project uses. Rename the skill folder and `name` to the tracker (e.g. `linear`, `jira`, `github-issues`) so the leading word matches how people talk.]]
---

<!-- FILL: This is a template. It encodes how agents read, start, move, and hand off issues. Replace every FILL marker, delete the branches this project does not use, and keep the shape: people, tools, issue shape, statuses, working an issue, QA comment, project management, changing the setup. The adoption guide (guides/skills.md in the starter repo) explains each section. -->

# [[FILL: tracker name]]

## People

| Who | Role | Account id |
| --- | --- | --- |
| [[FILL: owner]] | Owner. Approves tracker changes, does the `ready-for-human` work, and receives QA failures. | [[FILL]] |
| [[FILL: QA, if a person checks work]] | Checks work on [[FILL: the shared test environment]]. Passes or fails an issue. | [[FILL]] |
| [[FILL: agent account]] | The agents' account. The tracker CLI and the tracker MCP both act as it. | [[FILL]] |

<!-- FILL: Give agents their own tracker account. Every move and comment an agent makes is then visibly an agent's, and its permissions can differ from a person's. -->

## Tools

- [[FILL: the tracker MCP server, if any: what it reads and writes, which account it must be logged in as and how to check that before the first write, and any arguments every call needs (site id, content format).]]
- `[[FILL: task runner]] tracker` covers what the MCP cannot, such as `start` and raw API calls. `[[FILL: task runner]] tracker -- --help` lists its commands and where it finds credentials.
- [[FILL: traps agents have hit with this tracker's API, e.g. link direction reading backwards, a field update that replaces a whole list. Delete this line if none yet; add entries only as agents hit them.]]

## Issue shape

- **Type.** [[FILL: which issue types exist and when to use each. An epic holds a plan: its children are the work, and their "blocks" links are the order.]]
- **Labels.** Use only these:
  - [[FILL: area labels that name the code areas a change touches, and what adds them (a push hook, CI, by hand).]]
  - `ready-for-agent`: the description carries acceptance criteria an agent can verify.
  - `ready-for-human`: the work is a step only a person can do.
- **Agent-written descriptions and comments** lead with `## Summary` for a [person](../writing-for-humans/SKILL.md), then `## Detail for agents`. A reader who stops after the Summary can still act. Below the split, give evidence as `file:line`, log lines, and commands, and mark what you confirmed apart from what you inferred.
- **New features are spec-first.** The contract goes in the issue description under `## Detail for agents`, and [[FILL: owner]] approves it there before any code. Record the approval in an "Approved by [[FILL: owner]]" comment, and each later change to the contract in its own comment.

## Statuses

[[FILL: the status flow, e.g. Backlog → To do → In Progress → Dev Complete → QA → Ready → Done, plus Canceled.]]

| Move | Who |
| --- | --- |
| → In Progress | `[[FILL: task runner]] tracker -- start <KEY>`. |
| → Dev Complete | [[FILL: e.g. "The push to the integration branch, for each issue a pushed commit subject leads with."]] |
| Dev Complete → QA | [[FILL: e.g. "The staging deploy."]] |
| QA → Ready | [[FILL: the person doing QA, by hand.]] |
| Ready → Done | [[FILL: e.g. "The production deploy."]] |

<!-- FILL: Automate every move a machine can see (a push, a deploy) so status stays true without anyone remembering. Name where each automation's rules live, rather than copying them here. -->

**A move the automation reports it did not make is a hand move.** Make it, then fix the cause.

## Working an issue

1. **Start.** Run `[[FILL: task runner]] tracker -- start <KEY>` as your first action on an issue. It prints the issue and its comments. The comments are part of the brief, so read them all. Under the `orchestrate` skill, the orchestrator runs this step, and subagents leave the issue's status and assignee alone.
2. **Commit** with the subject `<KEY>: <subject>`, the key first. Context changes on a `context/<topic>` branch use the key too. A commit with no leading key moves nothing, so move its issue by hand.
3. **QA comment.** One is owed once the issue reaches [[FILL: the status that hands it to a person]]. Read the existing comments, then take the one branch that applies:
   - no QA comment yet: write the full one;
   - a QA comment already there: write only the steps for the work since, and name the comment they extend;
   - the existing steps cover every change: add nothing, and say why in your reply.

   The handoff is done when every area in the diff is named with where it is checked, and the comment is posted or its absence explained.

## QA comment

```markdown
## Summary

<One or two sentences: what changed for the person checking it.>

## What this issue changes

- <Area (plain gloss)>: <where it is checked>. <Action>. Expect <result>.

Not checkable on <environment>: <area>: <what verifies it, and when>. Skip it.

## Detail for agents

<Build, branch, and setup; the commits; what was verified, and how.>
```

- **Name each area the diff touched by its term plus a plain gloss**, such as `Admin (the admin console)`.
- **Write the steps as a [QA handoff](../writing-for-humans/SKILL.md#qa-handoff).** A docs-only change needs no QA: say so in the Summary.
- **Name the change, never a build.** Leave build numbers and SHAs out of the steps.

## Project management

<!-- FILL: Keep this section when agents help run the project, not only work its issues. Move each procedure to a sibling file (e.g. BOARD.md) once it grows past a few lines, and keep one pointer line per branch here. Delete the branches this project does not use. -->

For a board review, triage of new issues, backlog ranking, cleanup, a release or season rollover, or messaging the people above about the work, read [[FILL: BOARD.md]].

## Changing the tracker's setup

Before any change to the workflow, a status, a transition, the set of labels, or the board, read [[FILL: TRACKER-ADMIN.md]]. Status, transition, and label names are load-bearing in [[FILL: the tooling that moves issues]], and that file lists every place that breaks. Every change there needs [[FILL: owner]]'s approval of the specific change first.
