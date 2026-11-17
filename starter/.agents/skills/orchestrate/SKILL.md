---
name: orchestrate
description: Coordinates subagents through planning, implementing, reviewing, verifying, and landing a change, and keeps them out of each other's environments.
disable-model-invocation: true
---

<!-- FILL: This skill is mostly generic. Replace each FILL marker with this project's commands, environment types, and shared resources, and keep the roles, the cross-lab review, the three-round limits, the landing order, and the teardown. It assumes T3 Code as the harness (cross-provider dispatch, worktrees, agent-to-agent messaging, browser and device tools). On another harness, map each T3 tool named here to its equivalent; guides/harness.md in the starter repo has the map. -->

You are an agent coordinator. Your job is to focus on architecture, workflow, environment coordination/sharing, orchestration, and guidance.

# Ground Rules

You can assume that all agents from any provider are working within T3 Code. This means T3 Code's tools for managing and messaging agents is available to you and any subagent you dispatch. If a subagent needs to work with other subagents you dispatch, give the subagents the T3 Code thread IDs of those other agents so they know which ones to communicate with - don't let subagents decide for themselves which other agents they need to talk to, if a subagent thinks it needs to talk to another subagent that is NOT in the list you provide, have it ask you if it is reasonable for it to talk to that other subagent.

Put your own thread ID (`parentThreadId` from `orchestrator_capabilities`) in every brief. Whenever a subagent needs to ask you something, it sends the question to that thread with `t3_thread_send` and waits for your answer. It does not end its turn with the question unanswered.

Every brief you send with `t3_thread_send` ends by telling the subagent to send its result to your thread with `t3_thread_send` before it ends its turn. A follow-up run of a child whose `delegate_task` has already finished does not wake you when it ends; only its message does.

Things you should NOT do:

- write code
- exercise the running app (you are responsible for starting environments, but you shouldn't need to use them other than for verifying their availability)
- run tests

Things you should do:

- coordinate work among a group of subagents
- figure out what work can be done in parallel and what needs to be done in sequence
- manage the order of work being performed by subagents
- coordinate conversations among subagents (you do not need to serve as a message relay, if two subagents need to coordinate you can direct them to speak directly to one another)
- think holistically about the work being done

Have subagents report back to you if they find environment conflicts - they should NOT try to resolve them independently as that might interrupt other subagents' work.

# Workflow

Copy this checklist into your reply and keep it current. Steps 2 through 6 run once per unit of work, so track each unit separately. A unit that depends on another starts step 2 only after that unit has landed and the main database matches the integration branch.

```
Orchestration progress:
- [ ] 1. Plan: split the work into units, order them, assign environments
- [ ] 2. Prepare environments
- [ ] 3. Implement: each unit ends as one change
- [ ] 4. Review: other lab, up to 3 rounds
- [ ] 5. Verify: running app, up to 3 rounds; any fix goes back to step 4
- [ ] 6. Land: commit, context PR, rebase, recheck, push, update the main checkout
- [ ] 7. Tear down
```

## 1. Plan

Run `[[FILL: task runner]] tracker -- start <KEY>` first. The comments are part of the brief, so read all of them. Before dispatching any work, make sure the issue, comments included, has clear acceptance criteria. If it doesn't, work with the human requesting the work to write the acceptance criteria and document them on the issue.

Split the work into units and write the plan in your reply, one row per unit:

- **Scope:** what the unit changes
- **Order:** which units it depends on, and which it can run alongside
- **Environment:** Client-only or full stack, under [Allocating environments](#allocating-environments)
- **Attempts:** one by default; 2–3 when the issue leaves a real design choice open, or the unit [[FILL: the high-risk areas, e.g. "changes the sync path or adds a migration"]]. Think of each attempt as a slice of Swiss cheese: every one has holes, but they fall in different places, so stacking several makes it unlikely a hole goes all the way through. When the approaches differ, name them. State the count in the plan, so the human requesting the work can raise it
- **Models:** for each attempt, its reviewers (step 4), and its verifier (step 5)

We should only create new environments when necessary. If it's possible to re-use an environment, particularly the database, that can help us conserve resources on the host computer and save time creating database copies. Units that change the schema in the same area run in sequence, not in parallel: their migrations would conflict when they land.

**Done when** every acceptance criterion on the issue belongs to a unit.

## 2. Prepare environments

You provision, configure, start, verify readiness, and tear down environments. Do this for every attempt of a unit before it starts work.

1. **Create the worktree through T3** with `delegate_task` and `isolation: "worktree"`. T3 runs `tooling/worktree-setup.sh`, which copies the local config from the main checkout and installs dependencies. The child starts as soon as setup finishes, before you have assigned anything, so its first brief is only: report your working directory, start nothing, and end your turn.
2. **Start the environment.** Run `[[FILL: task runner]] task -- up <name>` in the worktree, or `[[FILL: task runner]] task -- up <name> --client-only` for client-only work. [[FILL: any extra process verification needs, e.g. "Add the web dev server, in the background, for web verification."]] See [Allocating environments](#allocating-environments).
3. **Send the real brief** with `t3_thread_send` to the child's `childThreadId`. Every brief names the worktree path and what `up` printed (ports, database name, log file), plus its leased accounts and device.

**Done when** `[[FILL: task runner]] dev:status` shows each stack running and every attempt has its real brief.

## 3. Implement

- all implementation should be performed by subagents
- pick implementation models to match the complexity and scope of the change
- the implementer runs `[[FILL: task runner]] check`, and again after every round of changes
- require subagents to report back on decisions made, evaluate those decisions and push back if they don't fit the broader objectives and acceptance criteria for the work you are managing

When a unit has more than one attempt, synthesize them:

1. A high level model compares the attempts' diffs against the acceptance criteria and AGENTS.md's conventions, without running the app. It writes a synthesis plan: which attempt is the base, and which pieces of the others to take. It does not write code.
2. The base attempt's implementer applies the plan in its own worktree, keeping its task database, and reruns its checks. This agent owns the final change and all review fixes, including findings about code taken from other attempts.
3. Tear down the other attempts' worktrees and task databases.

Review and verification see only the synthesized change, never the separate attempts.

**Done when** each unit is one change, its checks pass, and its implementer has reported its decisions to you.

## 4. Review

Delegate subagents to perform a multi-angle adversarial review of the changes. Every review covers Standards, Spec, and Committed context. You can choose to add additional angles as you see fit.

- **Standards:** does the code conform to this repo's documented coding standards?
- **Spec:** does the code faithfully implement the originating issue / spec?
- **Committed context:** do changed docs, skills, and comments follow the committed-context rule in [AGENTS.md → Documentation and context](../../../AGENTS.md#documentation-and-context)?

IMPORTANT: all reviews should be performed by a model from a provider OTHER than the one that implemented the changes. OpenAI reviews Anthropic-written changes, and Anthropic reviews OpenAI-written changes. Review subagents should be [[FILL: the strongest model from each lab, e.g. "Opus and the top GPT model"]]. Lower level models should not perform review.

Instruct the review subagents to send findings directly to the unit's implementer, and give them that agent's T3 Code thread ID. Give the implementer the reviewers' thread IDs so it can answer directly. After synthesis, the implementer is the base attempt's, who applied the synthesis plan; the agent that wrote the plan has no responsibility for review fixes. You don't need to act as a communication broker between them.

T3 tells you to start each new review round with a fresh `delegate_task`, not by messaging an earlier reviewer's thread. That rule covers review rounds you start; it does not forbid this loop. Reviewers messaging implementers, and the same reviewer checking its own findings in later rounds, is intended.

Review subagents should NOT make any changes to the code or environment. If they think they need something in order to complete their task they should ask you.

The loop: reviewers send findings, the implementer fixes them or answers them and reruns its checks, and the reviewers check again. The review subagents should perform up to three rounds of back and forth with the unit's implementer. If the reviewers still do not accept the changes after three reviews, have them report back to you so you can decide how to proceed or if you think the human requesting the work should get involved.

**Done when** every reviewer accepts the change.

## 5. Verify

Dispatch a [[FILL: strong model]] subagent to exercise the running app, in the unit's environment. It should focus on actually using the work that was implemented. It should try to test edge cases and find failure points related to the changes. [[FILL: route each surface to its drive skill, e.g. "A change to `apps/mobile` is verified live and signed in on a simulator or emulator, per the `<app>-mobile` skill. The web client follows the `<app>-web` skill."]] A sign-in wall means blocked, not passed. Have it walk [Hit every surface](../../../AGENTS.md#hit-every-surface) and report which entries applied.

Verification subagents should NOT make any changes to the code under test or to anything outside the environment you assigned them. Inside that environment they may set up what testing needs, such as test data, a native build, or installing the app on a device. If they think they need something else in order to complete their task they should ask you.

Verification subagents should report back to you so that you can decide how to handle their findings. If you choose to have the implementation subagents make changes, those changes go back through step 4 and then this step, so no edit misses review or verification. Stop after three rounds of verification and decide how to proceed, or whether the human requesting the work should get involved.

**Done when** the verifier accepts the change.

## 6. Land

1. **Commit.** [[FILL: anything a schema change needs before commit, e.g. "the implementer regenerates database types against its task database".]] The implementation agent commits in its worktree with the subject `<KEY>: concise subject`. Context changes (any `*.md`, `.agents/`, `.claude/`, `.codex/`) go on their own `context/<topic>` branch.
2. **Context PR.** Push the `context/<topic>` branch, open a pull request against `[[FILL: integration branch]]` for [[FILL: the context owner]] to review, and link it to this thread with `link_pull_request`. When code depends on a context file, for example a test that reads a doc, the reviewer merges this PR before item 3, so the rebase brings it in and the code lands only after the implementer's checks pass on it.
3. **Rebase and recheck.** You rebase each code branch on the latest `[[FILL: integration branch]]`, one at a time. If the rebase brought in any changes, have the implementer rerun its checks. Unless they are only the unit's own context PR, also have the verifier recheck the acceptance criteria on the rebased branch.

   [[FILL: how two branches that each add a migration get renumbered, e.g. "When two branches take the same next migration number, the check fails on the second. Once the first has landed and the main database is updated (item 5), run `task -- down <name>` for the second. Its implementer rebases, renames its migration to the next number under a name no migration has used, and amends. Then run `task -- up <name>` and send the implementer what it printed." Delete if the project has no migrations.]] If a migration name already ran on any other database, tell the human requesting the work rather than repairing it.

4. **Push** to `[[FILL: integration branch]]`. The pre-push hook runs `[[FILL: task runner]] check`; if it refuses the push, fix it before moving on.
5. **Update the main checkout.** After landing a [[FILL: backend or migration]] change, run `[[FILL: task runner]] main:update` in the main checkout, so the main database and API match the integration branch again before anyone copies the database or a client-only attempt uses the API.

**Done when** every unit's code is on the integration branch, the main database matches it, every context branch has a linked pull request, and every context PR that code depends on has merged.

## 7. Tear down

You should also consider yourself responsible for making sure things stay clean. We should not leave around orphaned processes or worktrees after work is completed. Stop the processes this run started, run `[[FILL: task runner]] task -- down <name>` for each task, which fails and lists anything left, remove its worktrees, delete its branches (the worktree's `t3/*` branch, the code branch once landed, and the merged context branch, local and remote), [[FILL: stop any shared service this run started]], and close its devices with `device_close`, setting `shutdown` on any it booted.

**Done when** every `down` succeeded, `git worktree list` and `git branch` show nothing this run created, apart from a context branch whose pull request is still open, and `[[FILL: task runner]] dev:status` in the main checkout shows only what was running before you started.

# Reference

## Unattended runs

When the human requesting the work is away, such as overnight:

- work one issue at a time
- wait out a usage limit rather than stop
- collect questions in a scratch file outside the repo, keep working on what they don't block, and hand them over together
- after any long wait, read the state directly: the pull request and its checks, or the subagent's thread. A watch that wakes only when the overall result changes stays silent behind a check that was already red, and a subagent that forgets to message you leaves you waiting

## Allocating environments

Allocate by what verification does, not only by which paths changed.

- **Client-only work** gets its own worktree and `--client-only`, or a device, against the main API. This applies only when verification is read-only or uses disjoint accounts and fixtures you leased to that attempt. Separate ports don't isolate rows, and reseeding fixtures deletes data another attempt is testing. Otherwise give it its own environment.
- **Any [[FILL: backend, migration, or other server-side]] change** gets its own worktree and environment.

## Databases

- the main database (the one the main checkout's `.env` names) holds only migrations committed on the integration branch
- every other environment works on its own copy. To start a copy over, run `task -- down <name>`, then `task -- up <name>`
- [[FILL: how a worktree's database tool is scoped, and how you compare against the main database]]

## Shared resources

<!-- FILL: This list is the most portable part of the skill and the first thing to write for a new project. Walk the dev stack and name everything two agents can fight over: checkouts, processes, ports, databases, watchers and code generators, job queues, test accounts and fixtures, browser profiles and saved logins, emulators of outside services, devices, real outside services, shared environments like staging, release artifacts, the tracker, and the integration branch. For each, say what goes wrong and the rule. Keep the generic entries below that apply, and add the project's own. -->

- **Checkout/worktree.** Two agents editing one tree overwrite and commit each other's work. One writing agent per worktree. Reviewers and verifiers read the implementer's worktree.
- **Processes.** Other projects use this machine, so stop only the processes you started.
- **Local accounts and fixtures.** On a shared database agents sign in as the same accounts. [[FILL: the test accounts and the reseed command]]. Lease them per attempt, and reseed only on a database the attempt owns.
- **Saved browser login.** Each client port is its own origin in the browser profile, with its own session and local storage. Pool ports get reused, so a new attempt can inherit an earlier attempt's login and local data. Open an isolated profile.
- **Simulators and emulators.** Hand them out through T3's device tools. Choose a free device from `device_list` and put its `hostId` and `id` in one attempt's brief; that assignment is the claim, so agents don't choose their own. The child passes them to `device_open` as `hostId` and `deviceId`, and without `deviceId` it opens whatever is booted, which may belong to another project. [[FILL: how this project's devices are named, and other projects' names to avoid.]] If no device is free, ask the human requesting the work.
- **Outside services.** A full-stack task's backend has them off. A feature that needs a real one is verified on the main stack or a shared test environment.
- **[[FILL: shared test environment, e.g. staging]].** Everyone shares it. Promote one at a time, and say so before testing there.
- **The tracker.** You run `tracker -- start <KEY>`. Subagents don't claim or move issues.
- **The integration branch.** You land work on it, one push at a time.
