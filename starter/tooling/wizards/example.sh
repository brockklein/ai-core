#!/usr/bin/env bash
#
# EXAMPLE WIZARD — copy this file to start a new wizard, then delete this one.
# It walks a made-up "Example service": capture an API key into .env, optionally copy it to a
# GitHub Actions secret, then check the result. Nothing here talks to a real service.
#
# A wizard — walks a human through a manual procedure step by step.
# tooling/wizards/lib/wizard.sh supplies the UI, the flags, and the closing summary. This file holds
# only the stages below the "STAGES" marker: one function per stage, registered with declare_stage,
# run by run_stages.
#
#   bash <this script> --list       list the stages and exit
#   bash <this script> --from N     run stage N onwards
#   bash <this script> --only N     run exactly stage N

set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/wizard.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/wizard.sh"

# ──────────────────────────────────────────────────────────────────────────
# STAGES — one stage_N() function per step, registered with declare_stage.
# ──────────────────────────────────────────────────────────────────────────

# Run from the repo root so ENV_FILE (.env) and every relative path below are stable.
cd "$(git rev-parse --show-toplevel)"

# need_api_key — re-derive the key stage 1 captured, or stop and name that stage. A later stage
# never assumes stage 1 ran in this process: --only / --from can start anywhere.
need_api_key() {
  EXAMPLE_API_KEY="$(_existing EXAMPLE_API_KEY || true)"
  if [[ -z "$EXAMPLE_API_KEY" ]]; then
    warn "EXAMPLE_API_KEY is not in $ENV_FILE yet. Stage 1 captures it:"
    show_cmd "bash $0 --only 1"
    exit 1
  fi
}

# Optional closing hook — runs once however the run ends, before the summary. Uncomment to use.
# wiz_on_close() {
#   note "closing hook: sync anything that must never be left half-done here."
# }

# ── Stage 1 · API key ─────────────────────────────────────────────────────
stage_1() {
open_url "https://example.com/dashboard/api-keys"
step "Example dashboard → Settings → API keys → Create key → copy it."
note "    (example.com is a placeholder — a real wizard names the real page and buttons.)"
say ""
ask_secret EXAMPLE_API_KEY "Paste the API key:"
if [[ -z "$EXAMPLE_API_KEY" ]]; then
  warn "No key entered, so nothing was written. Re-run: bash $0 --only 1"
  exit 1
fi
write_env EXAMPLE_API_KEY "$EXAMPLE_API_KEY"
pause
}
declare_stage "Example service — API key" stage_1

# ── Stage 2 · CI secret (skippable) ───────────────────────────────────────
stage_2() {
need_api_key
say "CI needs the key only if a workflow reads secrets.EXAMPLE_API_KEY."
if confirm "Store EXAMPLE_API_KEY as a GitHub Actions secret?"; then
  set_secret EXAMPLE_API_KEY "$EXAMPLE_API_KEY"
else
  note "Skipped — CI can't reach the example service until it's set."
  SKIPPED+=("GitHub secret EXAMPLE_API_KEY (re-run: bash $0 --only 2)")
fi
pause
}
declare_stage "Example service — GitHub Actions secret" stage_2

# ── Stage 3 · Check ───────────────────────────────────────────────────────
stage_3() {
need_api_key
say "Check that the key landed in $ENV_FILE. The command names the key and never prints its value."
run_cmd "grep -q '^EXAMPLE_API_KEY=.' $ENV_FILE && echo 'EXAMPLE_API_KEY is set in $ENV_FILE'"
pause "Press Enter to finish."
}
declare_stage "Example service — check" stage_3

# ── Run ───────────────────────────────────────────────────────────────────
banner "Example service — setup (example wizard: copy, then delete)"
run_stages

finish
