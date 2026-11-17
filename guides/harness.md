# The harness

The **harness** is the program that runs the agents: it starts them, gives them tools, and connects them to each other. The patterns in this repo depend on a harness that can do five things:

1. **Dispatch agents from more than one AI lab.** Cross-lab review needs an Anthropic model and an OpenAI model in the same workflow.
2. **Create an isolated git worktree for an agent** and run a setup script in it before the agent starts.
3. **Let agents message each other by id.** Reviewers send findings straight to the implementer, and any agent can ask the coordinator a question and wait for the answer.
4. **Drive the running product**: a browser for web surfaces, and iOS Simulators and Android Emulators for native ones.
5. **Link work to pull requests and watch them.**

## The recommendation: T3 Code

We recommend [T3 Code](https://t3.codes). It does all five things natively:

- `delegate_task` dispatches a child agent on any connected provider and model, with `isolation: "worktree"` for its own checkout. The project's worktree-setup script runs before the child starts.
- `t3_thread_send` sends a message to any thread by id, and `orchestrator_capabilities` gives the coordinator its own thread id and the models it can use.
- The preview browser (`preview_*` tools) drives web pages in isolated profiles. The device tools (`device_list`, `device_open`, `device_screenshot`, `device_close`) hand out simulators and emulators, and a person can watch them in the Device panel.
- `link_pull_request` and `watch_pull_request` tie pull requests to the thread that made them.

The `orchestrate` skill in `starter/` names these tools directly, because tool names are leading words an agent acts on reliably.

## Using another harness

The principles still hold. Map each capability to what your harness offers, and replace every T3 tool name in the adopted files with yours: the orchestrate skill, the drive skills, and the review rule in `AGENTS.md`'s Workflow section.

| Capability | T3 Code | Typical alternatives |
| --- | --- | --- |
| Dispatch a child agent | `delegate_task` | Claude Code `Agent` tool; Codex `spawn_agent`; a CLI started in the background (`claude -p`, `codex exec`) |
| Child on another lab's model | `delegate_task` with a target provider | Start the other lab's CLI as a process and read its output |
| Child in its own worktree | `isolation: "worktree"` plus the project setup script | `git worktree add`, then run `tooling/worktree-setup.sh` yourself before starting the child |
| Agent-to-agent messages | `t3_thread_send` to a thread id | Shared files in a run folder (`.orchestrate/<run>/<agent>.md`); or the coordinator relays |
| Coordinator's own id | `orchestrator_capabilities` | The run folder path |
| Drive a browser | `preview_*` tools | `playwright-cli`, Playwright MCP |
| Drive a simulator or emulator | `device_*` tools and `agent-device` | `xcrun simctl` and `adb` through an automation tool such as Maestro or Appium |
| Link and watch pull requests | `link_pull_request`, `watch_pull_request` | `gh pr create`, `gh pr checks --watch` |

Without direct messaging, the coordinator becomes the relay between reviewers and the implementer. That costs the coordinator context, so keep each message to findings and verdicts.

Without cross-lab dispatch, keep the review step and run it with a different strong model than the one that wrote the code, and with a fresh context. You lose some independence, so weigh a second review angle more heavily.
