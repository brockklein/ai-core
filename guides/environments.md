# Environments for parallel work

Several agents working at once on one machine collide in predictable ways. They edit the same tree, bind the same port, migrate the same database, reseed the same fixtures, and drive the same simulator. This guide covers how to stop that.

## Start with the shared-resources list

Before you write any tooling, walk the dev stack and list everything on the machine that two agents can fight over. For each item, write what goes wrong and the rule. This list is the most portable part of the whole approach. It ends up in the [orchestrate skill](../starter/.agents/skills/orchestrate/SKILL.md#shared-resources), and most tooling exists to enforce one of its rules.

Common entries:

| Resource | What goes wrong | Typical rule |
| --- | --- | --- |
| Checkout or worktree | Two agents overwrite and commit each other's work. | One writing agent per worktree. Reviewers and verifiers read the implementer's worktree. |
| The main checkout | Another session switches its branch, and a commit lands on the wrong branch. | Agents work in worktrees. The main checkout stays on the integration branch. |
| Processes | An agent stops another project's server. | Stop only what you started, proven by a recorded pid and start time. |
| Ports | Another project or worktree already listens on the port. | The environment manager assigns from a pool and records the lease. |
| `.env` files | A new worktree copies the main checkout's ports and database. | `task up` rewrites them; the app refuses a database until it has. |
| Database | A worktree's server applies its branch's migration to the shared database, and every other checkout then fails to boot. | Schema work happens on a database copy. The main database holds only migrations on the integration branch. |
| Watchers and code generators | A generator rewrites shared files from whatever schema the database holds. | One generator per database. |
| Job queues | Two servers on one database take each other's jobs. | One server per database, and empty the queue in a copy. |
| Test accounts and fixtures | A verifier reseeds fixtures and deletes data another attempt is testing. | Lease accounts per attempt. Reseed only a database the attempt owns. |
| Browser profiles | A new attempt inherits an earlier attempt's login and local storage on a reused port. | Open an isolated profile per verification. |
| Emulators of outside services | One test suite wipes data another suite needs. | One attempt holds the emulator for a whole suite. The coordinator starts and stops it. |
| Simulators and emulators | Two agents drive one device, or an agent opens another project's device. | The coordinator assigns a device in the brief. The assignment is the claim. |
| Native toolchains | A build lock looks like a hang. | One native build per checkout. |
| Outside services | A test sends a real push notification or email to a real person. | Off in every worktree stack. Verify a real one on the main stack or in staging. |
| Shared staging | Two promotions race, or a test changes data someone is using. | One promotion at a time; announce before use. |
| The tracker | Two agents move one issue. | Only the coordinator starts issues. |
| The integration branch | Two agents push at once. | Only the coordinator lands, one push at a time. |

## The environment manager

`starter/tooling/task-env.mjs` is a generic engine, and `task-env.config.mjs` holds the project's part. Its commands:

- **`task up <name> [--client-only]`** gives the worktree its own ports from a pool, a copy of the main database if the project has one, and its services. Rerun it freely: it restarts the stack and keeps the ports and database. `--client-only` runs only the client, against the main backend.
- **`task stop`** stops what `up` started here. It signals only a process group whose leader still matches the pid and start time it recorded. A group it can't prove is listed and left alone.
- **`task down <name>`** stops everything, removes the database copy, returns `.env` to the main checkout's values, and fails with a list if anything remains. It works for a name whose worktree is already gone.
- **`dev:status`** reports, read-only, what runs where.

The design choices behind it:

- **One rerunnable command.** The coordinator's brief to an implementer is then "here is what `up` printed": ports, database name, log file.
- **The unsafe default is impossible.** `worktree-setup.sh` copies the main checkout's `.env`, so a fresh worktree points at the main database. The app's env loader must refuse every database and job entry point in a worktree until `up` has run. **This guard matters more than any instruction.** Wire it into your app's config loading: `up` writes the task's name into the worktree's primary env file (the `taskKey` setting), and the loader refuses to start in a linked worktree when that key is missing. A Node app calls `assertTaskEnvironment()` from `task-env.mjs` at startup. An app in another language checks the same key in a few lines.
- **Database copies are local only.** The copy hook refuses a non-local URL, and it acts only on names it generates, so it can never name the main database.
- **Serialize.** `up`, `stop`, and `down` take a repo-wide lock, so two coordinators can't lease the same port.
- **Outside services always off.** A task stack never talks to a real third party. See [Tools](tools.md#principles) on one fixed setting.

### Keeping the main checkout current

After work that changes the backend or the schema lands, the main database and server must match the integration branch again, because the next database copy is made from it. A `main:update` command pulls, migrates the main database, and restarts what the change needs. The orchestrate skill runs it after each landing.

## Allocating environments

Allocate by what verification does, not only by which files changed:

- **Client-only work** shares the main backend through `--client-only`, but only when verification is read-only or uses accounts and fixtures leased to that attempt alone. Separate ports don't isolate rows.
- **Any backend, migration, or sync change** gets its own full environment.
- **Reuse when safe.** A database copy costs time and memory. Units that change the schema in the same area run in sequence, because their migrations conflict when they land.

## Devices

The coordinator picks a free device and puts its host id and device id in one attempt's brief. That assignment is the claim, and agents never choose their own device. An agent that opens a device without its id may get whatever is booted, which can belong to another project. Name each project's devices so ownership is visible, and stop on "device in use" instead of taking it over.

## Building it for your project

1. Write the shared-resources list. Walk `docker compose`, the dev scripts, `.env.example`, seed scripts, CI, and the test setup.
2. Fill `task-env.config.mjs`: services and the env keys that hold their ports, the port pool, the env files to rewrite, and the database copy and drop commands.
3. Add the worktree guard to the app's env loading.
4. Fill `worktree-setup.sh` with the gitignored files a worktree needs. Never include signing keys, deploy secrets, or service accounts: a worktree holds short-lived agent work.
5. Register `worktree-setup.sh` with the harness. In T3 Code, it is a project script with "run on worktree create".
6. Add `main:update`.
7. Copy the resource rules into the orchestrate skill's Shared resources section.
