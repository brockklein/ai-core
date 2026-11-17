#!/usr/bin/env bash
# expect() evals its single-quoted check later, and RC/OUT are read inside those checks.
# shellcheck disable=SC2016,SC2034
# Stubbed tests for the wizard library and every committed wizard. They stub gh, tmux, and the
# browser openers, and they run each case in a temporary git repo, so no test reaches GitHub, a
# browser, or a real .env.
#
#   bash tooling/wizards/test/wizards.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # tooling/wizards
# Every committed wizard, by file name without .sh. A wizard that declares stages must be listed.
WIZARDS="example"
PASSED=0; FAILED=0
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/wizard-tests.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
# A marker in every fake secret. No wizard output may ever contain it.
SECRET_MARK="s3cr3t-value-never-print"

pass() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/        /'; }
expect() { if eval "$2"; then pass "$1"; else fail "$1" "$OUT"; fi; }
has()    { printf '%s' "$OUT" | grep -qF -- "$1"; }
logged() { grep -qF -- "$1" "$STATE/log" 2>/dev/null; }
no_secret_printed() { ! printf '%s' "$OUT" | grep -qF "$SECRET_MARK"; }
hook_runs() { if [[ -f "$STATE/hook" ]]; then wc -l < "$STATE/hook" | tr -d ' '; else echo 0; fi; }

write_stubs() {
  mkdir -p "$STUBS"
  cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STATE/log"
case "$1 ${2:-}" in
  "auth status") [[ ! -f "$STATE/gh_signed_out" ]]; exit ;;
  "secret set")
    name="$3"
    [[ -f "$STATE/gh_set_fails" ]] && { echo "HTTP 500: set failed" >&2; exit 1; }
    cat > "$STATE/secret_${name}"; exit 0 ;;
  "variable set") echo "$5" > "$STATE/var_$3"; exit 0 ;;
esac
echo "unexpected gh call: $*" >&2; exit 99
STUB
  # run_cmd only prints outside tmux. This tmux runs the step script (its last argument), so a test
  # sees the exit-code gate work.
  cat > "$STUBS/tmux" <<'STUB'
#!/usr/bin/env bash
bash -c "${*: -1}" < /dev/null > /dev/null 2>&1 || true
STUB
  # open_url must never reach a real browser from a test.
  for browser in open xdg-open wslview; do printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/$browser"; done
  chmod +x "$STUBS"/*
}

# new_repo — a fresh sandbox: a git repo holding every wizard, the library, and the stubs.
new_repo() {
  local wizard
  CASE_DIR="$(mktemp -d "$SANDBOX/case.XXXXXX")"
  STATE="$CASE_DIR/state"; STUBS="$CASE_DIR/stubs"; WORK="$CASE_DIR/work"
  mkdir -p "$STATE" "$CASE_DIR/home" "$CASE_DIR/tmp" "$WORK/tooling/wizards/lib"
  git init -q "$WORK"
  for wizard in $WIZARDS; do cp "$ROOT/$wizard.sh" "$WORK/tooling/wizards/$wizard.sh"; done
  cp "$ROOT/lib/wizard.sh" "$WORK/tooling/wizards/lib/wizard.sh"
  write_stubs
}

# run_wiz STDIN SCRIPT ARGS… — run a wizard with the stubs. Sets OUT and RC.
run_wiz() {
  local input="$1" script="$2"; shift 2
  OUT="$(cd "$WORK" && printf '%b' "$input" | PATH="$STUBS:$PATH" STATE="$STATE" HOME="$CASE_DIR/home" \
    TMPDIR="$CASE_DIR/tmp" bash "$script" "$@" 2>&1)"
  RC=$?
}
# leftover_tmp — any replacement file a run left beside .env.
leftover_tmp() { [[ -n "$(find "$WORK" -maxdepth 1 -name '.env.tmp.*')" ]]; }

# A throwaway wizard: one wizard's preamble, which sources the library, plus stages that end the way
# a test needs. SYNTH_HOOK defines wiz_on_close: ok, fail, or exit (calls exit inside the hook).
synth() {
  local src="$ROOT/$1.sh" n
  n=$(grep -n '^# STAGES —' "$src" | cut -d: -f1)
  { sed -n "1,${n}p" "$src"; cat <<'BODY'
if [[ -n "${SYNTH_HOOK:-}" ]]; then
wiz_on_close() {
echo ran >> "$STATE/hook"
echo "hook output here"
[[ "$SYNTH_HOOK" != exit ]] || exit 3
false_if_fail() { [[ "$SYNTH_HOOK" != fail ]]; }
false_if_fail
echo "hook kept going" >> "$STATE/hook_after"
}
fi
WIZ_EXECUTION_NOTE="synth note"
stage_1() {
say "stage one"
if [[ "${SYNTH_MODE:-}" == fail ]]; then false; fi
if [[ "${SYNTH_MODE:-}" == wait ]]; then read -r _; fi
if [[ "${SYNTH_MODE:-}" == exit0 ]]; then exit 0; fi
if [[ "${SYNTH_MODE:-}" == redirect ]]; then { echo partial; false; } >> "$PWD/.env"; fi
if [[ "${SYNTH_MODE:-}" == swap ]]; then _WIZ_SWAP_TMP="$(mktemp "$PWD/.env.tmp.XXXXXX")"; false; fi
if [[ "${SYNTH_MODE:-}" == upsert ]]; then write_env NEW 1; write_env NEW 2; fi
if [[ "${SYNTH_MODE:-}" == run ]]; then run_cmd "${SYNTH_CMD:-true}"; fi
if [[ "${SYNTH_MODE:-}" == secret ]]; then set_secret S "$SECRET_VALUE"; set_var V public; fi
if [[ "${SYNTH_MODE:-}" == flag ]] && wiz_flag --dry; then say "dry flag seen"; fi
}
declare_stage "First stage" stage_1
stage_2() {
say "stage two"
}
declare_stage "Second stage" stage_2
banner "synth"
run_stages
finish
BODY
  } > "$WORK/tooling/wizards/synth.sh"
}

# run_sigint — a background job ignores SIGINT unless job control is on, so turn it on.
run_sigint() {
  local fifo="$CASE_DIR/fifo" pid out="$CASE_DIR/sigint.out" i
  rm -f "$fifo"; mkfifo "$fifo"
  exec 9<>"$fifo"
  set -m
  (cd "$WORK" && SYNTH_MODE=wait SYNTH_HOOK=ok PATH="$STUBS:$PATH" STATE="$STATE" HOME="$CASE_DIR/home" \
    TMPDIR="$CASE_DIR/tmp" exec bash tooling/wizards/synth.sh) <&9 > "$out" 2>&1 &
  pid=$!
  set +m
  printf '\n' >&9
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q 'stage one' "$out" && break
    perl -e 'select(undef,undef,undef,0.1)'
  done
  perl -e 'select(undef,undef,undef,0.2)'
  kill -INT "$pid"
  wait "$pid"; RC=$?
  exec 9>&-
  OUT="$(cat "$out")"
}

structure_tests() {
  local w lib="$ROOT/lib/wizard.sh" fns found
  echo "── One library"
  if bash -n "$lib"; then pass "lib/wizard.sh: bash -n"; else fail "lib/wizard.sh: bash -n"; fi
  # Every script that declares stages is a wizard, so each one gets the checks below.
  for w in "$ROOT"/*.sh; do
    grep -q '^declare_stage ' "$w" || continue
    w="${w##*/}"
    if [[ " $WIZARDS " == *" ${w%.sh} "* ]]; then pass "$w is in WIZARDS"; else fail "$w declares stages but is not in WIZARDS"; fi
  done
  fns="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$lib" | tr -d '()' | paste -sd '|' -)"
  for w in $WIZARDS; do
    if grep -qxF 'source "$(dirname "${BASH_SOURCE[0]}")/lib/wizard.sh"' "$ROOT/$w.sh"; then
      pass "$w: sources lib/wizard.sh"; else fail "$w: does not source lib/wizard.sh"; fi
    found="$(grep -oE "^($fns)\(\)" "$ROOT/$w.sh" | paste -sd ' ' -)"
    if [[ -z "$found" ]]; then pass "$w: carries no copy of the library"; else fail "$w: defines library functions: $found"; fi
    if bash -n "$ROOT/$w.sh"; then pass "$w: bash -n"; else fail "$w: bash -n"; fi
    OUT="$(cd "$ROOT/test" && bash "../$w.sh" --list 2>&1)"; RC=$?
    expect "$w: --list works from another directory" '[[ $RC == 0 ]] && has " stages"'
  done
}

flag_tests() {
  local s=tooling/wizards/synth.sh
  echo "── Flags and stage selection"
  new_repo; synth example
  run_wiz '' "$s" --list
  expect "--list prints every title in order and runs nothing" '[[ $RC == 0 ]] && has "2 stages" && has "1  First stage" && has "2  Second stage" && ! has "stage one"'
  run_wiz '' "$s" --help
  expect "--help shows the shared flags" '[[ $RC == 0 ]] && has "--from N" && has "--only N" && ! has "--no-sync"'
  run_wiz '' "$s" --bogus
  expect "an unknown option is a usage error" '[[ $RC == 2 ]] && has "unknown option: --bogus"'
  run_wiz '' "$s" --only 0
  expect "--only 0 is a usage error" '[[ $RC == 2 ]] && has "needs a stage number"'
  run_wiz '' "$s" --only 9
  expect "a stage past the end is a usage error" '[[ $RC == 2 ]] && has "no such stage: 9"'
  run_wiz '\n' "$s"
  expect "a full run shows Stage i/N and finishes" '[[ $RC == 0 ]] && has "Stage 1/2 · First stage" && has "Stage 2/2 · Second stage" && has "Setup complete"'
  run_wiz '\n' "$s" --only 2
  expect "--only 2 runs just stage 2 with its real number" '[[ $RC == 0 ]] && has "running ONLY stage 2 of 2" && has "Stage 2/2" && ! has "stage one"'
  run_wiz '\n' "$s" --from=2
  expect "--from=2 starts at stage 2" '[[ $RC == 0 ]] && has "running stages 2–2" && ! has "stage one" && has "stage two"'
  run_wiz '\n' "$s"
  expect "WIZ_EXECUTION_NOTE replaces the tmux tip" 'has "synth note" && ! has "Tip: run inside tmux"'
  sed -i.bak '1a\
WIZ_OWN_FLAGS="--dry|do nothing for real"' "$WORK/$s"
  run_wiz '' "$s" --help
  expect "an own flag shows in --help" '[[ $RC == 0 ]] && has "[--dry]" && has "do nothing for real"'
  SYNTH_MODE=flag run_wiz '\n' "$s" --only 1 --dry
  expect "wiz_flag sees an own flag this run passed" '[[ $RC == 0 ]] && has "dry flag seen"'
  SYNTH_MODE=flag run_wiz '\n' "$s" --only 1
  expect "wiz_flag is false when the run did not pass it" '[[ $RC == 0 ]] && ! has "dry flag seen"'
}

close_tests() {
  local s=tooling/wizards/synth.sh
  echo "── Closing hook and summary"
  new_repo; synth example
  run_wiz '\n' "$s"
  expect "no wiz_on_close means a plain finish" '[[ $RC == 0 ]] && has "Setup complete" && ! has "closing step"'
  SYNTH_HOOK=ok run_wiz '\n' "$s"
  expect "a clean finish calls wiz_on_close once, before the summary" '[[ $RC == 0 && "$(hook_runs)" == 1 ]] && printf "%s" "$OUT" | grep -A100 "hook output here" | grep -qF "Setup complete"'
  rm -f "$STATE/hook" "$STATE/hook_after"
  SYNTH_HOOK=fail run_wiz '\n' "$s"
  expect "a failing hook is reported in the summary and is not fatal" '[[ $RC == 0 ]] && has "closing step failed" && has "wiz_on_close) failed with exit 1"'
  expect "the hook runs under set -e (stops at its first failure)" '[[ ! -f $STATE/hook_after ]]'
  SYNTH_HOOK="exit" run_wiz '\n' "$s"
  expect "exit inside the hook cannot skip the summary" '[[ $RC == 0 ]] && has "failed with exit 3"'
  rm -f "$STATE/hook"
  SYNTH_HOOK=ok SYNTH_MODE=fail run_wiz '\n' "$s"
  expect "a stage that fails under set -e still runs the hook once, and exits non-zero" '[[ $RC != 0 && "$(hook_runs)" == 1 ]] && has "stopped before the last stage (exit 1)"'
  rm -f "$STATE/hook"
  SYNTH_HOOK=ok SYNTH_MODE=exit0 run_wiz '\n' "$s"
  expect "a stage that exits 0 early runs the hook, and does not claim success" '[[ $RC == 0 && "$(hook_runs)" == 1 ]] && ! has "Setup complete" && has "stopped before"'
  rm -f "$STATE/hook"; run_sigint
  expect "Ctrl-C at a prompt runs the hook, and exits 130" '[[ $RC == 130 && "$(hook_runs)" == 1 ]]'
  rm -f "$STATE/hook"
  SYNTH_HOOK=ok run_wiz '' "$s" --list
  expect "--list runs no hook" '[[ $RC == 0 && "$(hook_runs)" == 0 ]]'
  SYNTH_HOOK=ok run_wiz '' "$s" --only 9
  expect "a usage error runs no hook" '[[ $RC == 2 && "$(hook_runs)" == 0 ]]'
  SYNTH_MODE=redirect run_wiz '\n' "$s"
  expect "the summary from a stage stopped in a redirect reaches the terminal, not the file" '! grep -q "stopped before" "$WORK/.env" && has "stopped before"'
}

env_tests() {
  local s=tooling/wizards/synth.sh
  echo "── .env writes"
  new_repo; synth example
  printf 'KEEP=%s\n' "$SECRET_MARK" > "$WORK/.env"
  SYNTH_MODE=upsert run_wiz '\n' "$s" --only 1
  expect "write_env upserts a value, and keeps the others, in a private file" '[[ $RC == 0 ]] && grep -qx "NEW=2" "$WORK/.env" && ! grep -qx "NEW=1" "$WORK/.env" && grep -q "^KEEP=" "$WORK/.env" && [[ -n "$(find "$WORK/.env" -perm 600)" ]] && has "wrote 2 value(s)"'
  SYNTH_MODE=swap run_wiz '\n' "$s" --only 1
  expect "a stop mid-replacement removes the temp file" '[[ $RC != 0 ]] && ! leftover_tmp'
  chmod 000 "$WORK/.env"
  SYNTH_MODE=upsert run_wiz '\n' "$s" --only 1
  chmod 600 "$WORK/.env"
  expect "write_env stops on an unreadable file, and keeps its values" '[[ $RC != 0 ]] && grep -q "^KEEP=" "$WORK/.env" && ! leftover_tmp'
}

gh_tests() {
  local s=tooling/wizards/synth.sh
  echo "── GitHub secrets and variables"
  new_repo; synth example
  SECRET_VALUE="$SECRET_MARK" SYNTH_MODE=secret run_wiz '\n' "$s" --only 1
  expect "set_secret pipes the value to gh, and never prints it" '[[ $RC == 0 && "$(cat "$STATE/secret_S")" == "$SECRET_MARK" ]] && no_secret_printed && ! logged "$SECRET_MARK" && has "set 1 GitHub secret(s): S"'
  expect "set_var sets the variable" '[[ "$(cat "$STATE/var_V")" == public ]]'
  expect "with no WIZ_GH_REPO, gh picks the current repo" '! logged "--repo"'
  : > "$STATE/log"
  WIZ_GH_REPO=acme/app SECRET_VALUE=x SYNTH_MODE=secret run_wiz '\n' "$s" --only 1
  expect "WIZ_GH_REPO targets that repo" 'logged "gh secret set S --repo acme/app" && logged "gh variable set V --body public --repo acme/app"'
  touch "$STATE/gh_signed_out"
  SECRET_VALUE=x SYNTH_MODE=secret run_wiz '\n' "$s" --only 1
  expect "gh signed out is listed as still to do, not fatal" '[[ $RC == 0 ]] && has "still to do by hand" && has "gh secret set S" && has "gh variable set V"'
  rm -f "$STATE/gh_signed_out"; touch "$STATE/gh_set_fails"
  SECRET_VALUE=x SYNTH_MODE=secret run_wiz '\n' "$s" --only 1
  expect "a failed gh secret set is listed as still to do" '[[ $RC == 0 ]] && has "skipped GitHub secret S"'
}

run_cmd_tests() {
  local s=tooling/wizards/synth.sh
  echo "── run_cmd"
  new_repo; synth example
  SYNTH_MODE=run SYNTH_CMD='touch ran' run_wiz '\n\n' "$s" --only 1
  expect "outside tmux, run_cmd shows the command and runs nothing" '[[ $RC == 0 && ! -f $WORK/ran ]] && has "$ touch ran" && has "no tmux session"'
  SYNTH_MODE=run SYNTH_CMD='touch <file>' TMUX=stub run_wiz '\n\n' "$s" --only 1
  expect "a command with a <placeholder> is never offered to run" '[[ $RC == 0 ]] && has "unsubstituted <placeholder>" && ! has "Run it now"'
  SYNTH_MODE=run SYNTH_CMD='touch ran' TMUX=stub run_wiz '\ny\n' "$s" --only 1
  expect "inside tmux, a consented command runs and is gated on exit 0" '[[ $RC == 0 && -f $WORK/ran ]] && has "step succeeded"'
  rm -f "$WORK/ran"
  SYNTH_MODE=run SYNTH_CMD='touch ran' TMUX=stub run_wiz '\nn\n\n' "$s" --only 1
  expect "a declined command is not run" '[[ $RC == 0 && ! -f $WORK/ran ]]'
  SYNTH_MODE=run SYNTH_CMD='exit 4' TMUX=stub run_wiz '\ny\nc\n' "$s" --only 1
  expect "a failed command offers the menu, and continue goes on" '[[ $RC == 0 ]] && has "step FAILED (exit 4)" && has "continuing despite exit 4"'
  SYNTH_MODE=run SYNTH_CMD='exit 4' TMUX=stub run_wiz '\ny\na\n' "$s" --only 1
  expect "abort stops the wizard" '[[ $RC == 1 ]] && has "aborting"'
  expect "run_cmd leaves no scratch dir" '[[ -z "$(find "$CASE_DIR/tmp" -name "wizard-run.*")" ]]'
}

example_tests() {
  local w=tooling/wizards/example.sh
  echo "── example.sh"
  new_repo
  run_wiz '' "$w" --list
  expect "--list prints 3 stages" '[[ $RC == 0 ]] && has "3 stages"'
  run_wiz '\n\n' "$w" --only 2
  expect "stage 2 stops without the key and names stage 1" '[[ $RC != 0 ]] && has "--only 1" && [[ ! -f $STATE/secret_EXAMPLE_API_KEY ]]'
  run_wiz '\n\n' "$w" --only 3
  expect "stage 3 stops without the key and names stage 1" '[[ $RC != 0 ]] && has "--only 1"'
  run_wiz '\n\n\n' "$w" --only 1
  expect "stage 1 refuses an empty key and writes nothing" '[[ $RC != 0 && ! -f $WORK/.env ]]'
  run_wiz "\n$SECRET_MARK\n\n" "$w" --only 1
  expect "stage 1 writes the key to .env without printing it" '[[ $RC == 0 ]] && grep -qx "EXAMPLE_API_KEY=$SECRET_MARK" "$WORK/.env" && no_secret_printed && has "opening"'
  run_wiz '\n\n\n' "$w" --only 1
  expect "a re-run of stage 1 keeps the saved key on Enter" '[[ $RC == 0 ]] && grep -qx "EXAMPLE_API_KEY=$SECRET_MARK" "$WORK/.env" && has "Enter keeps current"'
  run_wiz '\ny\n\n' "$w" --only 2
  expect "stage 2 re-reads the key and sets the secret" '[[ $RC == 0 && "$(cat "$STATE/secret_EXAMPLE_API_KEY")" == "$SECRET_MARK" ]] && no_secret_printed'
  run_wiz '\nn\n\n' "$w" --only 2
  expect "stage 2 lists a declined secret as still to do" '[[ $RC == 0 ]] && has "still to do by hand" && has "--only 2"'
  TMUX=stub run_wiz '\ny\n\n' "$w" --only 3
  expect "stage 3 runs its check and passes" '[[ $RC == 0 ]] && has "step succeeded" && no_secret_printed'
}

structure_tests
flag_tests
close_tests
env_tests
gh_tests
run_cmd_tests
example_tests
printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
