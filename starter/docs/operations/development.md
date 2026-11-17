# Development

<!-- FILL: The first-time setup a person follows on a new machine, in order, each step with its command and how to tell it worked: toolchain install, dependencies, local config (.env from .env.example, and where each secret comes from — or a wizard that captures them), local services (database, queues), seed data, running the app, running the checks. End with how worktrees get their own environment (`task -- up <name>`) so parallel agents don't collide. Keep it a procedure; decisions go in docs/internals/. -->

## 1. [[FILL: Install the toolchain]]

## 2. [[FILL: Configure local settings]]

## 3. [[FILL: Start local services]]

## 4. [[FILL: Run the app]]

## 5. [[FILL: Run the checks]]

## Worktrees

A worktree starts with the main checkout's local config, copied by `tooling/worktree-setup.sh`. Run `[[FILL: task runner]] task -- up <name>` in it before anything touches a database, and `[[FILL: task runner]] task -- down <name>` when the work has landed.
