# Orchestration

One agent coordinates, and other agents do the work. The coordinator moves each change through seven steps, and gives every writing agent an isolated environment. The procedure lives in the user-invoked [orchestrate skill](../starter/.agents/skills/orchestrate/SKILL.md). A person starts it on purpose, for an issue or an epic.

## The roles

| Role | Does | Does not |
| --- | --- | --- |
| **Coordinator** | Plans units of work, prepares environments, briefs subagents, judges their decisions, lands the work, tears down | Write code, run tests, or use the app |
| **Implementer** | Writes one change in its own worktree, runs the checks, reports its decisions, answers reviewers | Share a worktree with another writing agent |
| **Synthesizer** | When a unit has several attempts, compares the diffs and writes a plan for combining them | Write code |
| **Reviewer** | Reviews the diff from one angle and sends findings straight to the implementer | Change code or the environment |
| **Verifier** | Uses the feature in the running app, tries to break it, and walks "hit every surface" | Change the code under test |

The coordinator gives each subagent the ids of the agents it may talk to, and its own id for questions. A subagent with a question sends it and waits for the answer. It does not end its turn with the question open. A subagent that finds an environment conflict reports it and does not fix it, because the fix can break another agent's work.

## The seven steps

The coordinator copies a checklist into its reply and keeps it current. Steps 2 to 6 run once for each unit of work.

1. **Plan.** Start the issue and read every comment. Make sure the acceptance criteria are clear, and write them with the person if not. Split the work into units, each with its scope, order, environment, number of attempts, and models. *Done when* every acceptance criterion belongs to a unit.
2. **Prepare environments.** Create the worktree through the harness, run `task up`, and only then send the real brief with what `up` printed. *Done when* `dev:status` shows each stack and every attempt has its brief.
3. **Implement.** Each attempt writes its change and runs the checks. With several attempts, a strong model writes a synthesis plan, the base attempt's implementer applies it, and only then are the other attempts torn down.
4. **Review.** Strong models from the other lab review from at least three angles: Standards, Spec, and Committed context. Reviewers and the implementer go back and forth directly for up to three rounds.
5. **Verify.** A separate agent uses the feature in the running app. Any fix goes back through review, then verification. Up to three rounds.
6. **Land.** Commit, open the context pull request, rebase on the integration branch one unit at a time, recheck if the rebase brought changes, push, and update the main checkout.
7. **Tear down.** `task down` for each task, remove the worktrees, delete the branches, and release devices. *Done when* `git worktree list`, `git branch`, and `dev:status` show nothing the run created.

## Why it is shaped this way

- **The coordinator writes no code.** Its context goes to the whole job: order, environments, and judgment. It pushes back on implementer decisions that don't fit the acceptance criteria.
- **The other lab reviews.** A different lab's model is less likely to share the blind spots of the model that wrote the code. Only strong models review.
- **Three review angles.** Standards and Spec catch code problems. Committed context catches docs, skills, and comments that break the context rules. A review catches nothing on those rules unless it is asked to look.
- **Review and verification are separate checks.** A typecheck passes on most bugs that matter. A verifier using the product catches what reading misses.
- **Every edit goes through every check.** A fix from verification goes back through review.
- **Every loop has a limit and a way out.** Three rounds, then the coordinator decides or brings in a person.
- **One attempt by default.** Extra attempts cost a worktree, a database, ports, device time, and two to three times the tokens. Use two or three when a real design choice is open, or for the project's riskiest changes, such as migrations. The count goes in the plan so the person can raise it.
- **Context lands through a person.** The context pull request is opened before the code rebases. Code that depends on a context change waits for the merge, so the code's checks run against the context it will ship with.
- **Leave the machine as you found it.** Teardown is a step with a check, and it deletes branches too.

## Practices for running it

- **Tear down attempts only after synthesis is applied.** The base implementer may need to read code from the other attempts.
- **After synthesis, review findings go to the base implementer,** who owns the final change and every fix, including fixes to code taken from other attempts. The synthesizer has no review duties.
- **The first brief to a new worktree agent is "report your directory, start nothing, and end your turn".** The harness starts the child as soon as setup finishes, before the coordinator has assigned ports or a database.
- **Watch for missed wakes.** A coordinator waiting on a pull request or CI can sit idle when a watch fires only on a change of overall state. For example, a check that is already red can hide the later results. After a long wait, read the state directly instead of trusting the watch.
- **Unattended runs need defaults.** For an overnight run, decide in advance: one issue at a time, wait out usage limits rather than stop, run CI's checks locally if CI minutes run out, and collect questions for the person in a scratch file outside the repo.
- **Run one coordinator at a time per project.** Several coordinators would need a shared registry of leases and devices. The environment manager's lock protects ports, but not plans.
- **Fix it now.** Don't defer a fix in the hope that the agent working a later issue will notice the same problem.
- **Define a sweeping scope with a command.** For a task like "review every file agents read", define the scope as a command (`git ls-files '*.md' .agents .claude .codex .mcp.json`), and require a report on every file. A hand-written list misses files.
- **Before a cleanup, move live work state to the tracker.** A cleanup that deletes notes can delete the record of work in progress.

## Filling the skill for your project

The `FILL:` markers in the orchestrate skill ask for:

- the tracker's `start` command,
- the project's riskiest change types, which get extra attempts,
- the `task up`, `dev:status`, `check`, and `main:update` commands,
- the review and verification models,
- the drive skill for each surface,
- what a schema change needs before commit, and how two branches that each add a migration get renumbered,
- the integration branch and the person who reviews context,
- and, above all, the **shared-resources list** from [Environments](environments.md).

Keep the roles, the cross-lab review, the three-round limits, the landing order, and the teardown. Those carry the approach.
