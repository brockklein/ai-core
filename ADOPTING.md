# Adopting the starter in a project

The procedure for an agent asked to set up a project ("the target") to follow this repo's approach. Read [README.md](README.md) first for the principles, and read each guide when its step names it.

The result is one pull request in the target that adds or rewrites its agent context, tooling, skills, and harness config. A person reviews it. This pull request is the one sanctioned mix of context and code: the hooks it adds refuse such a mix, so they are activated only after it merges (step 10).

## Fit the procedure to the target

Every step assumes the mechanism exists in the target. When the survey shows it doesn't, take the branch below, and record the choice for the pull request's "Dropped" list.

| The target has no… | Then |
| --- | --- |
| database | Set `database: null` in `task-env.config.mjs`. Skip the worktree guard and the database MCP server. Step 5 is done when `task up` and `task down` give a worktree its own ports and processes. |
| long-running services (a library, a CLI) | Skip `task-env` and `dev:status`. Keep `worktree-setup.sh` for dependencies and local config. The verifier exercises the product through its tests, a sample project, or the CLI itself. |
| user-facing surface | Skip the drive skills. Route verification in `orchestrate` to whatever exercises the product end to end. |
| issue tracker | Skip the tracker skill and `start`. Acceptance criteria live in the pull request description, and commit subjects use `<area>:` only (set `ISSUE_KEY_RE` to a pattern nothing matches). |
| separate integration branch (pull requests into `main`) | Set the integration branch to `main`. Agents land through pull requests instead of direct pushes: adapt orchestrate's Land step, and leave `PROTECTED_BRANCHES` empty, relying on server-side branch protection. |
| harness with cross-lab dispatch | Follow the fallback in [guides/harness.md](guides/harness.md#using-another-harness) everywhere review is required. |


Copy this checklist into your reply and keep it current:

```
Adoption progress:
- [ ] 1. Prepare a branch
- [ ] 2. Survey the target
- [ ] 3. Settle decisions with the person
- [ ] 4. Copy the starter
- [ ] 5. Build the environments and tools
- [ ] 6. Write the context
- [ ] 7. Fill the skills
- [ ] 8. Configure the harness
- [ ] 9. Verify
- [ ] 10. Hand off
```

## 1. Prepare a branch

Work in a worktree or branch of the target named `context/agent-setup`. Create it from the branch the target's pull requests merge into. If you can't tell which branch that is yet, use the default branch and rebase in step 10 once the survey settles it. Commit only to this branch.

**Done when** `git status` in the target shows the new branch, clean.

## 2. Survey the target

Facts are your job, never the person's. Read the target and write survey notes in your scratch space, not in the repo. If your harness can dispatch subagents, split the survey among them by area. Cover:

- **Product and parts:** what the product is, each app or service and its stack, and the legacy systems it replaces.
- **Commands:** the task runner (`package.json` scripts, `Makefile`, `mise`, `just`, `rake`) and every dev, test, lint, build, codegen, migrate, seed, and deploy command.
- **Branches and release:** the protected branch, the integration branch, how code reaches staging and production, and CI workflows and their triggers.
- **Dev stack:** every service, port, database, queue, watcher, code generator, emulator, and outside service, plus the `.env` files and their keys, and which local files are gitignored.
- **Tracker:** which tracker, the project key, the statuses, the labels, and any automation.
- **Existing agent context:** `AGENTS.md`, `CLAUDE.md`, `.cursor/`, `.github/copilot-instructions.md`, existing skills, `docs/`, and READMEs. Note each rule or warning they contain.
- **Existing guardrails:** git hooks, lint rules, CI checks, and branch protection.
- **Surfaces:** each way a person uses the product (web desktop, web mobile, iOS, Android, admin console, CLI, API), and how each can be driven locally.

**Done when** every bullet above has an answer or a recorded "none", and you can write the shared-resources list from [guides/environments.md](guides/environments.md) without guessing.

## 3. Settle decisions with the person

Put only decisions to the person, with your recommendation for each, in one round, in the format of the [grilling](starter/.agents/skills/grilling/SKILL.md) skill. Typical decisions:

- the integration branch agents land on, and the branch only a person moves;
- who reviews context pull requests, and who owns the project (named in `AGENTS.md`);
- the harness. Recommend T3 Code ([guides/harness.md](guides/harness.md)), and map tool names if the person picks another;
- which surfaces need a drive skill;
- whether agents should help run the project (the tracker skill's Project management section);
- which models review and verify;
- anything in the survey where two existing rules conflict.

**Done when** the person has answered every question or accepted your recommendation.

## 4. Copy the starter

Copy `starter/` into the target root. Never overwrite an existing file: merge into it. Keep the target's own content and conventions, and move them into the starter's structure in step 6.

- Copy `.agents/skills/` and create the symlink `.claude/skills -> ../.agents/skills`. If the target already has `.claude/skills` as a folder, move its skills into `.agents/skills/` first.
- Rename `drive-app` to one folder per surface (`<app>-web`, `<app>-mobile`), and rename `issue-tracker` to the tracker's name. Update the `name` fields and every link to them.
- Put `starter/tooling/` files where the target keeps scripts. If that is not `tooling/`, update every path that names them, in scripts and skills alike.
- Adapt scripts to the target's languages when needed. The starter assumes Node 22 and bash. If the target has no Node, port the `.mjs` tools to its main language and keep their behavior and self-tests.

Add `.task/` to the target's `.gitignore`. The environment manager keeps process records and logs there.

**Done when** every starter file has a place in the target, and `git check-ignore .task/x` matches.

## 5. Build the environments and tools

Read [guides/environments.md](guides/environments.md) and [guides/tools.md](guides/tools.md).

1. Write the shared-resources list from your survey.
2. Fill `task-env.config.mjs` and `worktree-setup.sh`. Expose the commands through the target's task runner as `task`, `dev:status`, `check`, and `main:update`, or as the closest names the target's conventions allow.
3. Add the worktree guard to the app's env loading, so database and job entry points refuse to run in a worktree until `task up` has run. This is the step that most often gets skipped. Do not skip it.
4. Fill `repo.conf`. Add the wiring for `hooks/pre-push` and `hooks/commit-msg` to the target's hook manager config, but do not install them in your checkout: they would refuse this adoption's own mixed branch. The person installs them after the merge.
5. Add the checks (`check-markdown-links`, `check-mcp-parity`, and the subject check) to the target's `check` command and to CI.
6. Walk every warning from the survey's existing context. For each, try rung 1 (eliminate) and rung 2 (catch) before it may become text in step 6. Record which rung each one took.

**Done when** `task up test_adoption` and `task down test_adoption` succeed in a scratch worktree of the target, `dev:status` reports correctly in both checkouts, the guard refuses a database command in a worktree before `up` (if the target has a database), and the self-tests pass.

## 6. Write the context

Read [guides/context.md](guides/context.md) and the [writing-for-agents](starter/.agents/skills/writing-for-agents/SKILL.md) skill.

1. Fill `AGENTS.md` from the survey. Keep only what every agent needs on every task.
2. Move each existing file of *agent instructions* (rules files, old `AGENTS.md` or `CLAUDE.md` content, agent-facing notes) to `docs/internals/`, `docs/operations/`, a directory's own `AGENTS.md`, a comment beside the code, or the tracker. Delete it if the code already says it. Leave human documentation where it is (public docs, tutorials, contribution guides), and link to it from `docs/README.md` when agents need it. Fill `docs/README.md` with an entry for each doc, written as the topics it covers.
3. Fill `docs/glossary.md` from the terms the survey found with several names or meanings.
4. Make `CLAUDE.md` contain only `@AGENTS.md`. Merge any content it had into `AGENTS.md` first.
5. Remove every committed-context violation you carried over: history, dates, provenance, and duplicated facts.

**Done when** no `FILL:` marker remains in the context files, every existing agent instruction has a recorded destination, and `node <tooling>/check-markdown-links.mjs` passes.

## 7. Fill the skills

Read [guides/skills.md](guides/skills.md) and [guides/orchestration.md](guides/orchestration.md).

- Fill `orchestrate`, above all its Shared resources section.
- Fill each drive skill. Start each one up for real: launch the surface, sign in, and drive one flow, and write down only what it took. Leave its Gotchas list nearly empty. It grows from real stumbles.
- Fill the tracker skill. Build the tracker CLI's `start <KEY>` command if the target lacks one: it moves the issue, assigns the agents' account, and prints the description and every comment.
- Fill the QA section of `writing-for-humans`.
- Leave the generic skills unchanged, apart from their `FILL:` markers.

**Done when** no `FILL:` marker remains under `.agents/skills/`.

## 8. Configure the harness

- Register `worktree-setup.sh` to run when the harness creates a worktree. In T3 Code, that is a project script with "run on worktree create".
- Fill `.claude/settings.json`: replace `main` in every deny rule with the protected branch from `repo.conf`, and fill the production command. These rules add to the hook and to server-side branch protection; they do not replace either.
- **On another harness**, replace every T3 tool name with your harness's equivalent, using the map in [guides/harness.md](guides/harness.md). Search the whole target, not only the skills: `AGENTS.md` names `delegate_task` for review, and the verify step below requires cross-lab review.
- Fill `.mcp.json` and `.codex/config.toml` with the same servers: the tracker MCP and a database tool scoped to the checkout, if the target has a database.
- If the agents need their own tracker account or test login, and creating it requires a person, write a wizard for it with the [wizard](starter/.agents/skills/wizard/SKILL.md) skill rather than a prose list of steps.

**Done when** `check-mcp-parity` passes and the settings file is valid JSON.

## 9. Verify

- `scripts/check-fill-markers.sh <target>` from this repo lists nothing.
- The target's `check` passes, including the new checks and the tool self-tests.
- In a scratch clone with a local bare remote and the hooks installed, the hooks refuse a push of a context file to the integration branch.
- **Read test:** start a fresh agent in the target with a minimal task prompt, and ask which context files it opened and why. Repeat with two other tasks. Fix pointers that missed, and cut loads that no task needed.
- **Review:** have a strong model from the other AI lab review the whole diff from the Standards, Spec (this procedure), and Committed context angles. Resolve or answer every finding.

**Done when** every item above passes.

## 10. Hand off

Push `context/agent-setup`, and open a pull request against the target's integration branch. Write its description with the [writing-for-humans](starter/.agents/skills/writing-for-humans/SKILL.md) skill:

- **Summary:** what the person gets, and what they must do: review, run any wizard, create accounts, and after the merge install the hooks in the main checkout (give the exact command).
- **Decisions:** each decision from step 3 and its answer.
- **Where the old context went:** each existing doc or rule, and its destination or its ladder rung.
- **Dropped:** each starter part that the target has no use for, and why.
- **Open questions:** collected, not scattered.

**Done when** the pull request is open and linked, and the person has its link.
