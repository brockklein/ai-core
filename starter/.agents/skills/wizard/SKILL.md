---
name: wizard
description: Generate an interactive bash wizard that walks a human through steps only they can perform. Use when provisioning infrastructure, setting up credentials or CI secrets, walking an unfamiliar third-party dashboard, or running a one-off migration or cutover. Don't invoke this for steps the agent can perform itself.
---

# Wizard

A **wizard** is a bash script that walks a human, step by step, through a manual procedure that's tedious to do by hand and tedious to re-explain to an AI every time. It opens each URL, says exactly what to click and copy, captures the values, writes them where they belong (`.env`, GitHub secrets), confirms at every stage, and shows how many stages are left. It might configure third-party services, run a one-off migration, or move the project from one state to another.

The delightful UX is already solved by the wizard library, [`tooling/wizards/lib/wizard.sh`](../../../tooling/wizards/lib/wizard.sh), which every wizard sources — stage-by-stage progress, confirmation gates, cross-platform URL opening (including WSL), hidden secret entry, idempotent `.env` upserts, `gh secret`/`gh variable` writes, stage selection (`--list` / `--from N` / `--only N`), an optional closing hook (`wiz_on_close`), and a closing summary. Risky state-changing commands go through `run_cmd`: it shows the exact command, then (with per-command consent, when the wizard runs inside tmux) executes it in a split pane so the operator watches live output while the wizard gates progression on the exit code — with retry/manual/continue/abort on failure — and falls back to copy/paste outside tmux or on decline. **Your job is only to scope the procedure and author its stages.** Change the library only for a change every wizard should get, then run `bash tooling/wizards/test/wizards.test.sh`.

A wizard is ephemeral by default — built for one run, deleted when the job's done. Write it in `tooling/wizards/` either way, so its `source` line finds the library. Commit it only when the user wants a repeatable setup path that should live in the repo.

## Process

### 1. Scope the procedure

Work out every manual step the human must take and every value that gets captured along the way. Read the repo first — don't ask cold:

- For setup: `.env`, `.env.example`, `.env.*`, `README`, `docker-compose*`, framework config, and `.github/workflows/*` (every `secrets.*` / `vars.*` reference is a value the wizard must produce).
- For a migration or transition: the current state, the target state, and the irreversible actions between them.

Then show the user the ordered list of stages and the values each produces, and confirm — they may add, drop, or reorder.

**Done when:** every stage is named in order, and for each captured value you know (a) where the human gets it, (b) where it's written (`.env`, a GitHub secret, both, or nowhere — some stages are pure actions), and (c) whether it's secret (hidden entry) or public.

### 2. Map each stage's journey

For each stage, write the precise path a human follows: which URL to open, what to do there, where a value is shown, which variable it fills — e.g. "Dashboard → Developers → API keys → Reveal test key → copy". Where you don't actually know the current UI or the exact command, say so and ask the user or check the docs — never invent steps that may not exist.

**Done when:** every stage traces to concrete instructions a stranger could follow.

### 3. Author the wizard

Start from [`tooling/wizards/example.sh`](../../../tooling/wizards/example.sh), the shortest committed wizard: copy it to `tooling/wizards/<wizard>.sh`, keep its preamble (the header, `set -euo pipefail`, and the `source` line), and replace its stages below the `STAGES` marker with one **function per step**, in dependency order, each registered right where it's written:

```bash
# ── Stage 1 · API keys ────────────────────────────────────────────────────
stage_1() {
say "…"
open_url "https://dashboard.stripe.com/test/apikeys"
ask_secret STRIPE_SECRET_KEY "Paste the secret key:"
write_env STRIPE_SECRET_KEY "$STRIPE_SECRET_KEY"
pause
}
declare_stage "Stripe — API keys" stage_1
```

and one `run_stages` between `banner` and `finish` at the bottom. `declare_stage` call order _is_ stage order; the title lives there and nowhere else, so `--list` can print every title without executing a body. `run_stages` renders the `▸ Stage i/TOTAL` header itself — a body never calls `stage` — and `TOTAL_STAGES` comes from the registry, so there is no count to keep in sync. Bodies are written **flush-left** inside the braces: a stage then reads exactly like the top-level script it would otherwise be.

Use the library helpers — `say`/`step`/`note`/`warn`, `open_url`, `ask`/`ask_secret`, `write_env`, `set_secret`/`set_var`, `pause`/`confirm`, and `run_cmd` for runnable state-changing commands.

**Every stage must be startable on its own.** `--from N` and `--only N` exist so a human who needs stage 7 doesn't walk 1–6, which means a later stage may never assume an earlier one ran _in this process_. For each value a stage sets and a later stage reads, do one of two things — never a third:

- **re-derive it** — read it back from the file the earlier stage wrote (`_existing KEY`, or a small `need_<thing>` helper that re-runs the derivation), or
- **stop** — print exactly which stage captures it and how to run it (`bash $0 --only N`), then `exit 1`.

Silently continuing with an empty value is the failure mode this rule exists to prevent (an empty `-c` config path, a command against an empty object key). The same applies to any _setting_ an earlier stage established — e.g. a wizard that points `ENV_FILE` at different files per stage must set it at the top of every stage that writes, not once at the top of the run.

Hold the bar the committed wizards set: open the URL before asking for its value, use `ask_secret` for anything secret, `write_env` every persisted value, `set_secret` only the values CI actually needs, and `confirm` before any irreversible action. Each stage clears the screen so only the current step is visible — keep a stage to one focused task so nothing the human needs scrolls away.

### 4. Verify and hand off

- `bash -n <script>`; run `shellcheck` if available.
- A committed wizard joins `WIZARDS` in `tooling/wizards/test/wizards.test.sh`; run that test.
- `bash <script> --list` — safe (it lists and exits), and it proves every stage registered in the right order with the title you meant.
- `chmod +x <script>`.
- Don't run it end-to-end yourself — it opens browsers and blocks on human input. Trace it statically instead: every value from step 1 is captured and lands where step 1 said, every `set_secret` name exactly matches a `secrets.*` reference in CI, and every cross-stage value is re-derived or refused per step 3.
- Tell the user how to run it — the whole thing, and the fact that they can re-enter it anywhere:

  ```bash
  bash tooling/wizards/<wizard>.sh            # all stages
  bash tooling/wizards/<wizard>.sh --list     # what the stages are
  bash tooling/wizards/<wizard>.sh --only 7   # just stage 7
  bash tooling/wizards/<wizard>.sh --from 7   # stage 7 to the end
  ```

  If it's a repeatable setup path, commit it and link it from the README so the next person runs the script instead of asking an AI.
