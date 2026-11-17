---
name: drive-app
description: [[FILL: "Driving the <app> <surface> locally in <browser or device tool>, signed in against the local stack. Use when verifying a change to <paths>, or to QA an issue against its acceptance criteria." Write one skill per surface that needs different driving (e.g. `<app>-web`, `<app>-mobile`), and name each after the app so the leading word matches how people talk.]]
---

<!-- FILL: This is a template. A verifier agent reads it to use the real product the way a person would. Copy it once per surface (web in a browser, iOS/Android on a simulator or emulator, a CLI, a desktop app), fill it, and delete what does not apply. The adoption guide (guides/skills.md in the starter repo) explains each section. Start small: launch, sign in, drive, tear down. Grow the gotchas only from stumbles agents actually hit. -->

# Drive [[FILL: app and surface]]

## 1. Start from your assignment

You have an environment (a worktree with its own stack, or the main stack) and, for a device surface, a device. If nobody assigned you an environment, start one with `[[FILL: task runner]] task -- up <name>`. `[[FILL: task runner]] dev:status` shows what runs where.

Reseed fixtures with `[[FILL: the seed command]]` only on a database your assignment owns.

## 2. Launch

[[FILL: the exact commands that serve this surface against this checkout's ports, which of them run in the background, and how to tell it is ready (poll a URL, wait for a log line). Name what a code change needs to show up: hot reload, a rebuild, a relaunch.]]

## 3. Open it

<!-- FILL: Pick the driving tool and keep its recipe here. With T3 Code: the preview browser (`preview_status`, `preview_open` with an isolated profile and `reuseExistingTab: false`, `preview_resize`, `preview_evaluate`, `preview_act`, `t3_preview_close`) or the device tools (`device_list`, `device_open` with `hostId` and `deviceId`, then the `agent-device` command it returns). Elsewhere: `playwright-cli` or Playwright MCP for a browser, the platform's automation tool for a device. Whatever the tool, open an isolated session so you inherit no other agent's login or local data, and claim a device only when your brief assigns it. -->

[[FILL: the opening steps, including viewport or device profile.]]

## 4. Sign in

Sign in as [[FILL: the account your brief leases, or how to create the agent's test account (e.g. an `agent-admin` command that makes sure it exists, so no person has to hand an agent a password)]]. Done when [[FILL: what the screen shows once signed in]]. A sign-in wall means the test is blocked, not passed.

## 5. Exercise the change

Drive the flows your change touches, and try to break them: edge cases, empty states, the reverse action, a reload in the middle. When a flow writes data, confirm the row reached your database with [[FILL: the database tool, e.g. an MCP `psql` tool scoped to this checkout]].

The test is done when you hold a screenshot or snapshot that shows the changed behavior on every surface the change touches.

## 6. Tear down

[[FILL: close the tab or device session you opened, and stop only the processes you started. Leave `task down` to whoever started the stack.]]

## QA an issue

A black-box pass, the way a human tester works. It needs an issue key; without one, report that and stop.

1. Fetch the issue with its comments and attachments. Its acceptance criteria are the checklist. When it has none, test the description's intent and say the criteria were absent.
2. Confirm the running app serves the branch under test. When you cannot, report that as a blocker.
3. For each criterion, decide whether a person could exercise it through the UI. Mark the rest `UNVERIFIABLE` now, with the reason.
4. Drive each exercisable criterion through the UI. Proof is what the app shows; source, config, schema, and branch stay as they are, and data changes only through in-app actions. Save a screenshot of every pass and fail, and record exact repro steps for a fail. After four failed attempts at one interaction, stop and report what you saw.
5. Report each criterion as `VERIFIED` (with evidence), `FAILED` (with repro steps and evidence), or `UNVERIFIABLE` (with the reason). Lead with the counts per verdict, the headline result, any blockers, and the `UNVERIFIABLE` criteria someone must confirm another way.

QA is done when every criterion carries a verdict with evidence or a reason.

## Gotchas

<!-- FILL: Group by phase (opening and building, signing in and data, driving, alerts and links). Each entry is one trap and the move that gets past it. Add one only after agents hit it more than once; delete one when a fix in code removes the trap. -->

- [[FILL]]
