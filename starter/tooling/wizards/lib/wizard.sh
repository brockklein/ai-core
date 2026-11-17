# shellcheck shell=bash
#
# The wizard library: the UI, the stage registry, the flags, and the closing summary. Every wizard
# in tooling/wizards/ starts with these lines, then declares its stages:
#
#   set -euo pipefail
#   # shellcheck source-path=SCRIPTDIR
#   # shellcheck source=lib/wizard.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/wizard.sh"
#
# It parses the wizard's own arguments, so source it with none. A wizard that takes a flag of its
# own sets WIZ_OWN_FLAGS before that source line, one "--flag|help text" per line. The library then
# accepts the flag, lists it in --help, and wiz_flag --flag says whether this run passed it.
#
# Settings a wizard (or the operator's environment) may set:
#   ENV_FILE       the dotenv file write_env / _existing / ask use (default: .env, relative to $PWD).
#   WIZ_GH_REPO    "owner/name" for set_secret / set_var. Unset, gh picks the repo of the current
#                  checkout, which is right for almost every wizard.
#
# Optional closing hook: a wizard may define a function `wiz_on_close`. The library calls it once
# when the run closes, whether every selected stage finished or the run stopped early (a failed
# stage, an early exit, Ctrl-C), and before the closing summary. It is the one place for work that
# must happen however the run ends, such as syncing a local secrets file to its remote copy, so no
# stage can forget it. It runs in a subshell under `set -e`: it cannot end the wizard or skip the
# summary, and it cannot change the wizard's variables. A non-zero exit is reported in the summary
# and does not change the wizard's exit code. It is not called for --list, --help, a usage error,
# or a stop before run_stages starts, because none of those ran a stage.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────
# Wizard library — delightful, consistent UX.
# ──────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

# Derived from the stage registry by _wiz_prepare (see the bottom of this
# library) — authors never set it; it stays a variable so `Stage i/TOTAL` and
# the banner keep reading the same name.
TOTAL_STAGES=0

_STAGE_INDEX=0
ENV_FILE="${ENV_FILE:-.env}"
WRITTEN_ENV=()    # KEYs written to ENV_FILE this run
WRITTEN_SECRET=() # secret NAMEs set this run
SKIPPED=()        # things we couldn't do (e.g. gh missing)

_WIZ_ARMED=0      # run_stages started, so the EXIT trap must close the run
_WIZ_CLOSED=0     # the closing summary has printed
_WIZ_HOOK_RC=""   # wiz_on_close's exit code; empty when the wizard defines no hook
_WIZ_SWAP_TMP=""  # a replacement file in progress, removed if the run stops before the rename
# Saved so the EXIT trap prints to the terminal. A stage can stop inside a redirected group, and the
# closing summary must never land in the file that group writes.
exec 198>&1 199>&2

# _clear — wipe the terminal so only the current step is on screen. No-op when
# output isn't a terminal, so piped logs stay readable.
_clear() {
  [[ -t 1 ]] || return 0
  if command -v tput >/dev/null 2>&1; then tput clear; else printf '\033[2J\033[3J\033[H'; fi
}

# banner "Title" — opening frame: what this wizard does.
banner() {
  _wiz_prepare
  _clear
  printf '\n%s%s  %s%s\n' "$BOLD" "$BLUE" "$1" "$RESET"
  printf '%s  %s stages%s\n\n' "$DIM" "$TOTAL_STAGES" "$RESET"
  printf '%s  You drive the browser; this wizard tells you exactly what to do and\n' "$DIM"
  printf '  captures the values you copy back. Stop any time with Ctrl-C and re-run\n'
  printf '  later — it remembers values already saved.%s\n' "$RESET"
  _wiz_selection_note
  if [[ -n "${WIZ_EXECUTION_NOTE:-}" ]]; then note "$WIZ_EXECUTION_NOTE"
  elif [[ -z "${TMUX:-}" ]]; then printf '\n%s  Tip: run inside tmux and this wizard can execute risky commands in a split pane (else copy/paste).%s\n' "$DIM" "$RESET"; fi
  pause "Ready to start?"
}

# stage "Name" — clear the screen, then announce a stage and show progress.
# Clearing keeps only the current step on screen. run_stages calls this for you
# (setting the counter first), so stage bodies never call it themselves.
stage() {
  _clear
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ Stage %s/%s · %s%s\n' \
    "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}

# say "..." — a plain instruction line.
say()  { printf '  %s\n' "$1"; }
# step "..." — a numbered-feeling action the human takes in the browser.
step() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s⚠ %s%s\n' "$YELLOW" "$1" "$RESET"; }

# open_url URL — open in the human's browser, cross-platform incl. WSL.
open_url() {
  local url="$1"
  printf '  %s↗ opening%s %s\n' "$GREEN" "$RESET" "$url"
  { if   command -v wslview     >/dev/null 2>&1; then wslview "$url"
    elif command -v explorer.exe >/dev/null 2>&1; then explorer.exe "$url"
    elif command -v xdg-open    >/dev/null 2>&1; then xdg-open "$url"
    elif command -v open        >/dev/null 2>&1; then open "$url"
    else warn "couldn't open a browser — visit it manually: $url"; fi
  } >/dev/null 2>&1 || warn "couldn't open a browser — visit it manually: $url"
}

# pause "msg" — wait for the human to confirm they've done the manual part.
pause() {
  printf '  %s%s%s ' "$DIM" "${1:-Press Enter to continue}" "$RESET"
  read -r _ || true
}

# confirm "question" — y/N gate; returns success on yes.
confirm() {
  local reply=""
  printf '  %s? %s [y/N] ' "$YELLOW" "$1"
  read -r reply || true
  [[ "$reply" =~ ^[Yy] ]]
}

# show_cmd "…" — print a copy-pasteable command line, byte-exact. Used directly for
# print-only commands (placeholders, log tails) and by run_cmd below as the display step.
show_cmd() { printf '  %s$ %s%s\n' "$BOLD" "$1" "$RESET"; }

# run_cmd "<command>" — the primary helper for a RUNNABLE state-changing command.
# It ALWAYS shows the command first (via show_cmd — byte-exact: what is shown is
# what runs), then, when the wizard is running INSIDE tmux, offers to execute it in
# a split pane so the operator watches live output while the wizard learns the exit
# code and gates progression on it. Outside tmux, or on decline, it falls back to
# print + pause: the operator copy/pastes into another terminal.
#   · placeholder guard — a string still holding an unsubstituted <placeholder>
#     (matches <[a-z0-9_ -]*>) is NEVER offered to run: compose the full command
#     before calling run_cmd; this is only a backstop. It prints + pauses instead.
#   · non-zero exit → an (r)etry / (m)anual / (c)ontinue-anyway / (a)bort menu,
#     looped so retry-after-retry works (each retry runs in a fresh pane).
# Purely execution: it captures nothing and writes no env/secret files. Because the
# command is shown verbatim, never put a secret VALUE in it — read it from a file instead.
_RUN_TMPDIR=""   # per-process scratch dir for step scripts (created lazily below)
_RUN_COUNTER=0   # increments per executed step → step-N.sh / step-N.rc

# _run_cleanup — drop the scratch dir on exit. bash never runs an EXIT trap in a
# subshell (command substitutions / (...) leave it alone), so this only fires in
# the MAIN shell; the ${_RUN_TMPDIR:-} guard keeps it set -u-safe and a no-op
# (never disturbing the exit status) when run_cmd made no scratch dir.
_run_cleanup() {
  [[ -n "${_RUN_TMPDIR:-}" ]] && rm -rf "$_RUN_TMPDIR" 2>/dev/null || true
  [[ -n "${_WIZ_SWAP_TMP:-}" ]] && rm -f "$_WIZ_SWAP_TMP" 2>/dev/null || true
}

# The EXIT trap closes a run that stopped early, so a failed stage or a Ctrl-C still runs the
# closing hook and prints the summary. Bash skips an EXIT trap on some signals unless a signal trap
# calls exit, so these three do. Only kill -9 skips all of this.
trap _wiz_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# _run_tmpdir — ensure the per-process scratch dir exists. Sets _RUN_TMPDIR once;
# callers read the global (NOT via $(...), which would set it in a subshell only).
_run_tmpdir() {
  [[ -n "$_RUN_TMPDIR" ]] || _RUN_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/wizard-run.XXXXXX")"
}

# _run_in_tmux CMD — write CMD verbatim to step-N.sh (an EXIT-trap runner tail
# captures its exit code to step-N.rc even if CMD calls exit, prints a green/red
# "── exit <rc> ──" banner, and holds the pane open), run it in a tmux split from
# $PWD (self-contained — no env inheritance assumed), poll step-N.rc, then gate:
# exit 0 returns success; non-zero drives the r/m/c/a menu (retry = fresh pane).
# Only ever called from run_cmd, and only when already inside a tmux session.
_run_in_tmux() {
  local cmd="$1" dir script rcfile rc choice
  _run_tmpdir; dir="$_RUN_TMPDIR"
  while true; do
    _RUN_COUNTER=$((_RUN_COUNTER + 1))
    script="$dir/step-${_RUN_COUNTER}.sh"
    rcfile="$dir/step-${_RUN_COUNTER}.rc"
    {
      printf '#!/usr/bin/env bash\n'
      cat <<TAIL
__on_exit() {
  __rc=\$?
  printf '%s\n' "\$__rc" > $(printf '%q' "$rcfile")
  if [ "\$__rc" -eq 0 ]; then printf '\n${GREEN}── exit 0 ──${RESET}\n'
  else printf '\n${RED}── exit %s ──${RESET}\n' "\$__rc"; fi
  printf '${DIM}Enter to close this pane.${RESET} '; read -r _ || true
}
trap __on_exit EXIT
TAIL
      printf '%s\n' "$cmd"
    } > "$script"
    chmod +x "$script"
    if ! tmux split-window -h -c "$PWD" "bash $script"; then
      warn "couldn't open a tmux split — run it yourself in another terminal."
      pause
      return 0
    fi
    note "running in a tmux split — watch that pane; waiting for it to finish…"
    while [[ ! -f "$rcfile" ]]; do sleep 1; done
    rc="$(cat "$rcfile" 2>/dev/null || echo 1)"
    if [[ "$rc" == 0 ]]; then
      printf '  %s✓ step succeeded (exit 0)%s\n' "$GREEN" "$RESET"
      return 0
    fi
    printf '  %s✗ step FAILED (exit %s)%s\n' "$RED" "$rc" "$RESET"
    while true; do
      printf '  %s? (r)etry · (m)anual · (c)ontinue anyway · (a)bort [r/m/c/a] %s' "$YELLOW" "$RESET"
      read -r choice || true
      case "$choice" in
        r|R) note "retrying in a fresh pane…"; break ;;
        m|M) pause "Run/fix it yourself in another terminal, then Enter."; return 0 ;;
        c|C) warn "continuing despite exit $rc — operator override (logged)."; return 0 ;;
        a|A) warn "aborting — safe to re-run; completed stages are idempotent."; exit 1 ;;
        *)   note "choose r, m, c, or a." ;;
      esac
    done
  done
}

# run_cmd "<command>" — see the header above: show, guard, offer, run-or-fallback.
run_cmd() {
  local cmd="$1" ph='<[a-z0-9_ -]*>'
  show_cmd "$cmd"
  if [[ "$cmd" =~ $ph ]]; then
    note "contains an unsubstituted <placeholder> — fill it in and run it yourself."
    pause
    return 0
  fi
  if ! command -v tmux >/dev/null 2>&1 || [[ -z "${TMUX:-}" ]]; then
    note "no tmux session — run it yourself in another terminal, then continue."
    pause
    return 0
  fi
  if confirm "Run it now in a tmux split? (n = copy/paste yourself)"; then
    _run_in_tmux "$cmd"
  else
    pause
  fi
}

# _existing KEY — current value of KEY in ENV_FILE, if any.
_existing() {
  [[ -f "$ENV_FILE" ]] || return 1
  local line; line=$(grep -E "^${1}=" "$ENV_FILE" | tail -n1) || return 1
  printf '%s' "${line#*=}"
}

# ask KEY "Prompt" — read a value into $KEY. Offers the existing .env value as
# a default on re-runs (Enter keeps it). Visible input (non-secret).
ask() {
  local key="$1" prompt="$2" current input
  current=$(_existing "$key" || true)
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter keeps current]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -r input || true
  [[ -z "$input" && -n "$current" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

# ask_secret KEY "Prompt" — like ask, but input is hidden.
ask_secret() {
  local key="$1" prompt="$2" current input
  current=$(_existing "$key" || true)
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter keeps current]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -rs input || true
  printf '\n'
  [[ -z "$input" && -n "$current" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

# _wiz_upsert FILE KEY VALUE — set KEY=VALUE in FILE by renaming a complete replacement over it, so a
# stop at any point leaves the old file whole. The temp file sits beside FILE because a rename is
# atomic only inside one filesystem, and mktemp makes it private (0600). A FILE that cannot be read
# stops the wizard: treating it as empty would drop every other value.
_wiz_upsert() {
  local file="$1" key="$2" value="$3" rc=0
  _WIZ_SWAP_TMP="$(mktemp "$file.tmp.XXXXXX")"
  if [[ -e "$file" ]]; then
    grep -vE "^${key}=" "$file" > "$_WIZ_SWAP_TMP" 2>/dev/null || rc=$?
    if (( rc > 1 )); then
      warn "could not read $file, so it stays as it was."
      exit 1
    fi
  fi
  printf '%s=%s\n' "$key" "$value" >> "$_WIZ_SWAP_TMP"
  mv "$_WIZ_SWAP_TMP" "$file"
  _WIZ_SWAP_TMP=""
}

# write_env KEY VALUE — upsert KEY=VALUE into ENV_FILE (creates it; replaces
# any existing line). Idempotent.
write_env() {
  local key="$1" value="$2"
  _wiz_upsert "$ENV_FILE" "$key" "$value"
  WRITTEN_ENV+=("$key")
  printf '  %s✓ wrote%s %s → %s\n' "$GREEN" "$RESET" "$key" "$ENV_FILE"
}

# _wiz_gh_ready — true when gh is installed and signed in.
_wiz_gh_ready() {
  command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
}

# set_secret NAME VALUE — set a GitHub Actions repo secret via gh. The value goes on stdin, so it
# never appears in the process list. Targets the current checkout's repo, or WIZ_GH_REPO if set.
# Falls back to a warning (and records it) if gh is unavailable or unauthenticated.
set_secret() {
  local name="$1" value="$2"
  if _wiz_gh_ready; then
    if printf '%s' "$value" | gh secret set "$name" ${WIZ_GH_REPO:+--repo "$WIZ_GH_REPO"} >/dev/null 2>&1; then
      WRITTEN_SECRET+=("$name")
      printf '  %s✓ set%s GitHub secret %s\n' "$GREEN" "$RESET" "$name"
      return
    fi
  fi
  SKIPPED+=("GitHub secret $name (set it manually: gh secret set $name${WIZ_GH_REPO:+ --repo $WIZ_GH_REPO})")
  warn "skipped GitHub secret $name — gh not ready; set it later"
}

# set_var NAME VALUE — set a GitHub Actions repo variable (non-secret). Same repo rules as set_secret.
set_var() {
  local name="$1" value="$2"
  if _wiz_gh_ready; then
    if gh variable set "$name" --body "$value" ${WIZ_GH_REPO:+--repo "$WIZ_GH_REPO"} >/dev/null 2>&1; then
      printf '  %s✓ set%s GitHub variable %s\n' "$GREEN" "$RESET" "$name"
      return
    fi
  fi
  SKIPPED+=("GitHub variable $name (set it manually: gh variable set $name${WIZ_GH_REPO:+ --repo $WIZ_GH_REPO})")
  warn "skipped GitHub variable $name — gh not ready; set it later"
}

# _wiz_run_hook — call the wizard's wiz_on_close, if it defines one, and record its exit code. A
# subshell with set -e of its own: errexit is ignored inside anything run as `f || …`, so the hook
# is called with errexit off out here and on inside, which keeps a failing command from carrying on.
_wiz_run_hook() {
  declare -F wiz_on_close >/dev/null 2>&1 || return 0
  local had_e=0 rc=0
  [[ $- == *e* ]] && had_e=1
  set +e
  ( set -e; wiz_on_close )
  rc=$?
  (( had_e )) && set -e
  _WIZ_HOOK_RC="$rc"
}

# _wiz_close finish | stopped [RC] — run the closing hook, then print the closing summary. Only a
# clean finish clears the screen: an early stop must keep the stage's error visible.
_wiz_close() {
  local mode="$1" rc="${2:-0}" s
  _WIZ_CLOSED=1
  [[ "$mode" == finish ]] && _clear
  _wiz_run_hook
  if [[ "$mode" == stopped ]]; then
    if (( rc )); then
      printf '\n%s%s  ✗ The wizard stopped before the last stage (exit %s)%s\n' "$BOLD" "$RED" "$rc" "$RESET"
    else
      printf '\n%s%s  The wizard stopped before the last stage%s\n' "$BOLD" "$YELLOW" "$RESET"
    fi
  elif [[ -n "$_WIZ_HOOK_RC" && "$_WIZ_HOOK_RC" != 0 ]]; then
    printf '\n%s%s  ✗ The stages finished, but the closing step failed%s\n' "$BOLD" "$RED" "$RESET"
  else
    printf '\n%s%s  ✓ Setup complete%s\n' "$BOLD" "$GREEN" "$RESET"
  fi
  (( ${#WRITTEN_ENV[@]} ))    && note "wrote ${#WRITTEN_ENV[@]} value(s) to $ENV_FILE: ${WRITTEN_ENV[*]}"
  (( ${#WRITTEN_SECRET[@]} )) && note "set ${#WRITTEN_SECRET[@]} GitHub secret(s): ${WRITTEN_SECRET[*]}"
  if (( ${#SKIPPED[@]} )); then
    printf '\n'; warn "still to do by hand:"
    for s in "${SKIPPED[@]}"; do note "  - $s"; done
  fi
  if [[ -n "$_WIZ_HOOK_RC" && "$_WIZ_HOOK_RC" != 0 ]]; then
    printf '\n  %s✗ The closing step (wiz_on_close) failed with exit %s.%s\n' "$RED" "$_WIZ_HOOK_RC" "$RESET"
    say "Its output is above. Fix the cause, then re-run this wizard (any stage, e.g. --only 1)."
  fi
  printf '\n'
}

# finish — the normal end of a wizard.
finish() {
  _wiz_close finish
}

# _wiz_on_exit — EXIT trap. It closes a run that did not reach finish, then drops the scratch dir.
# It keeps the original exit code. A second Ctrl-C during the closing hook kills it, the same as
# kill -9.
_wiz_on_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  set +e
  exec 1>&198 2>&199
  if (( _WIZ_ARMED && ! _WIZ_CLOSED )); then
    # A Ctrl-C inside ask_secret can leave terminal echo off.
    [[ -t 0 ]] && stty echo 2>/dev/null
    _wiz_close stopped "$rc"
  fi
  _run_cleanup
  exit "$rc"
}

# ──────────────────────────────────────────────────────────────────────────
# Stage registry + stage selection (--list · --from N · --only N)
#
# Stage bodies are FUNCTIONS, registered in order right where they're written:
#
#     # ── Stage 1 · API keys ────────────────────────────────────────────
#     stage_1() {
#       say "…"; open_url "…"; ask FOO "…"; write_env FOO "$FOO"; pause
#     }
#     declare_stage "Example service — API keys" stage_1
#
# and a single `run_stages` (after `banner`) walks them. Registration stores
# data only, so `--list` prints every title without executing one body, and
# `--from N` / `--only N` can start anywhere. run_stages renders each header
# itself — a body never calls `stage`, and the header always shows the REAL
# stage number even when earlier stages were skipped.
# ──────────────────────────────────────────────────────────────────────────

_STAGE_TITLES=()   # stage titles, in declaration order
_STAGE_FNS=()      # parallel array: the function that runs that stage
_WIZ_LIST=0        # --list
_WIZ_SELECTION=0   # an explicit --from/--only/--stage, including --from 1
_WIZ_FROM=1        # --from N (default: the first stage)
_WIZ_TO=0          # --only N pins the last stage too; 0 = run to the end
_WIZ_READY=0       # _wiz_prepare has derived TOTAL_STAGES + validated the range
_WIZ_OWN_SET=" "   # the wizard's own flags this run passed, space-delimited

# declare_stage "Title" fn_name — register one stage. Call order IS stage order.
declare_stage() {
  _STAGE_TITLES+=("$1")
  _STAGE_FNS+=("$2")
}

# _wiz_usage — the shared --help text (identical in every wizard).
_wiz_usage() {
  local own="" line
  while IFS= read -r line; do if [[ -n "$line" ]]; then own="$own [${line%%|*}]"; fi; done <<< "${WIZ_OWN_FLAGS:-}"
  printf '\n%sUsage%s  bash %s [--list] [--from N] [--only N]%s\n\n' "$BOLD" "$RESET" "$0" "$own"
  printf '  %s%-12s%s %s\n' "$BOLD" "--list, -l" "$RESET" "print the numbered stage titles and exit (runs nothing)"
  printf '  %s%-12s%s %s\n' "$BOLD" "--from N"   "$RESET" "start at stage N and run through to the last stage"
  printf '  %s%-12s%s %s\n' "$BOLD" "--only N"   "$RESET" "run exactly stage N, then the closing summary (alias: --stage N)"
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then printf '  %s%-12s%s %s\n' "$BOLD" "${line%%|*}" "$RESET" "${line#*|}"; fi
  done <<< "${WIZ_OWN_FLAGS:-}"
  printf '  %s%-12s%s %s\n\n' "$BOLD" "--help, -h" "$RESET" "this message"
  printf '%s  With no options every stage runs in order. Stages are idempotent and\n' "$DIM"
  printf '  re-runnable, so re-running one — or all of them — is always safe.%s\n\n' "$RESET"
}

# _wiz_bad "msg" — usage error: say what's wrong, point at --list, exit 2.
_wiz_bad() {
  printf '\n  %s✗ %s%s\n' "$RED" "$1" "$RESET"
  printf '  see the stages with: %sbash %s --list%s\n\n' "$BOLD" "$0" "$RESET"
  exit 2
}

# _wiz_int N FLAG — N must be a stage NUMBER (1-based). The upper bound is checked
# later, in _wiz_prepare, once the registry is populated.
_wiz_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "${1:-}" != 0 ]] || _wiz_bad "$2 needs a stage number ≥ 1 (got '${1:-}')"
}

# _wiz_parse_args "$@" — invoked at the bottom of this library with the script's own
# arguments, so every wizard gets the same flags without authoring anything.
_wiz_parse_args() {
  local arg n
  while (( $# )); do
    arg="$1"
    case "$arg" in
      -l|--list)          _WIZ_LIST=1; shift ;;
      --from)             n="${2:-}"; _WIZ_SELECTION=1; _wiz_int "$n" "--from"; _WIZ_FROM="$n"; shift 2 ;;
      --from=*)           n="${arg#*=}"; _WIZ_SELECTION=1; _wiz_int "$n" "--from"; _WIZ_FROM="$n"; shift ;;
      --only|--stage)     n="${2:-}"; _WIZ_SELECTION=1; _wiz_int "$n" "$arg"; _WIZ_FROM="$n"; _WIZ_TO="$n"; shift 2 ;;
      --only=*|--stage=*) n="${arg#*=}"; _WIZ_SELECTION=1; _wiz_int "$n" "${arg%%=*}"; _WIZ_FROM="$n"; _WIZ_TO="$n"; shift ;;
      -h|--help)          _wiz_usage; exit 0 ;;
      *)
        if _wiz_own_flag "$arg"; then _WIZ_OWN_SET="$_WIZ_OWN_SET$arg "; shift
        else _wiz_usage; _wiz_bad "unknown option: $arg"; fi ;;
    esac
  done
}

# _wiz_own_flag ARG — true when the wizard declared ARG in WIZ_OWN_FLAGS.
_wiz_own_flag() {
  local line
  while IFS= read -r line; do if [[ -n "$line" && "${line%%|*}" == "$1" ]]; then return 0; fi; done <<< "${WIZ_OWN_FLAGS:-}"
  return 1
}

# wiz_flag FLAG — true when this run passed FLAG, one of the wizard's own WIZ_OWN_FLAGS.
wiz_flag() { [[ "$_WIZ_OWN_SET" == *" $1 "* ]]; }

# _wiz_prepare — derive TOTAL_STAGES from the registry, serve --list, and range-check
# the selection. Called by banner() and run_stages(); the second call is a no-op.
_wiz_prepare() {
  local i
  (( _WIZ_READY )) && return 0
  _WIZ_READY=1
  TOTAL_STAGES=${#_STAGE_TITLES[@]}
  if (( _WIZ_LIST )); then
    printf '\n%s%s%s  %s%s stages%s\n\n' "$BOLD" "${0##*/}" "$RESET" "$DIM" "$TOTAL_STAGES" "$RESET"
    i=0
    while (( i < TOTAL_STAGES )); do
      printf '  %s%2s%s  %s\n' "$BLUE" "$(( i + 1 ))" "$RESET" "${_STAGE_TITLES[$i]}"
      i=$(( i + 1 ))
    done
    printf '\n%s  just one:  bash %s --only N        from one on:  bash %s --from N%s\n\n' "$DIM" "$0" "$0" "$RESET"
    exit 0
  fi
  (( TOTAL_STAGES )) || _wiz_bad "this wizard registered no stages (declare_stage was never called)"
  (( _WIZ_FROM <= TOTAL_STAGES )) || _wiz_bad "no such stage: $_WIZ_FROM — this wizard has $TOTAL_STAGES"
  (( _WIZ_TO <= TOTAL_STAGES )) || _wiz_bad "no such stage: $_WIZ_TO — this wizard has $TOTAL_STAGES"
}

# _wiz_selection_note — one line under the banner when the run is a SUBSET, so the
# operator can never mistake a partial run for a full one.
_wiz_selection_note() {
  (( _WIZ_FROM > 1 || _WIZ_TO )) || return 0
  if (( _WIZ_TO )); then
    printf '\n%s  running ONLY stage %s of %s — every other stage is skipped.%s\n' "$YELLOW" "$_WIZ_TO" "$TOTAL_STAGES" "$RESET"
  else
    printf '\n%s  running stages %s–%s of %s — earlier stages are skipped.%s\n' "$YELLOW" "$_WIZ_FROM" "$TOTAL_STAGES" "$TOTAL_STAGES" "$RESET"
  fi
  printf '%s  A stage that needs a value an earlier one captured re-reads it from disk,\n' "$DIM"
  printf '  or stops and names the stage to run first.%s\n' "$RESET"
}

# run_stages — run the registered stages, honouring --from/--only. Sets the stage
# counter per stage so "Stage i/TOTAL" is the real number, then calls the body.
run_stages() {
  local i last
  _wiz_prepare
  last=$TOTAL_STAGES
  (( _WIZ_TO )) && last=$_WIZ_TO
  # Armed here, not earlier: --list, --help, a usage error, and a stop at the banner ran no stage,
  # so they get no closing hook and no summary.
  _WIZ_ARMED=1
  i=$_WIZ_FROM
  while (( i <= last )); do
    _STAGE_INDEX=$(( i - 1 ))
    stage "${_STAGE_TITLES[$(( i - 1 ))]}"
    "${_STAGE_FNS[$(( i - 1 ))]}"
    i=$(( i + 1 ))
  done
}

# Parse the wizard's own CLI flags now that every helper above exists. Stage
# selection is validated later (in _wiz_prepare), once the registry is populated.
_wiz_parse_args "$@"
