#!/usr/bin/env bash
# Commit subject check, for the commit-msg hook, the pre-push hook, and CI.
#
#   tooling/check-commit-subjects.sh <before> [<after>]      # every commit in <before>..<after>
#   tooling/check-commit-subjects.sh --message-file <file>   # the commit-msg hook
#
# Refuses a commit whose subject is not one of:
#   <ISSUE-KEY>: <subject>   issue work; ISSUE_KEY_RE in tooling/repo.conf (e.g. ABC-123: ...)
#   <area>: <subject>        non-issue work; <area> is lowercase (ci, deploy, context, ...)
# Exactly one space follows the colon, and the subject starts right after it.
#
# Why: tracker automation and humans scanning `git log` find work by the issue key, and an agent
# writing a vague subject ("Fix stuff") loses that link silently. A subject that names the issue
# or area also tells the reviewer what the commit is for before they read the diff.
#
# Exempt: merge commits, and git-generated reverts (`Revert "..."`, plus `Reapply "..."`, which git
# writes when it reverts a revert).
#
# An empty, all-zero, or unknown <before> (a new branch, or a force-push whose old tip is gone)
# checks <after> alone.
#
# Self-test: tooling/test/checks.test.sh
set -euo pipefail

# [a-z] must not depend on the locale's collation order.
export LC_ALL=C

tooling_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=repo.conf
. "$tooling_dir/repo.conf"

valid_re="^(${ISSUE_KEY_RE}|[a-z][a-z0-9_-]*): [^[:space:]]"
revert_re='^(Revert|Reapply) "'

subject_ok() {
  [[ "$1" =~ $valid_re ]] || [[ "$1" =~ $revert_re ]]
}

# The `::error::` prefix means something only in a GitHub Actions log.
report() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error::$1"
  else
    echo "$1"
  fi
}

hint='Start it with "<ISSUE-KEY>: " for issue work or a lowercase "<area>: " otherwise (e.g. "ci: ").'

if [ "${1-}" = "--message-file" ]; then
  [ -n "${2-}" ] || { echo "usage: $0 --message-file <file>" >&2; exit 2; }
  # Git runs commit-msg on merge commits too, and on the message before it strips comments.
  if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    exit 0
  fi
  subject="$(grep -v -E '^[[:space:]]*(#|$)' "$2" | head -n1 || true)"
  if subject_ok "$subject"; then
    exit 0
  fi
  report "Commit subject \"${subject}\" does not match the required format. ${hint}"
  exit 1
fi

before="${1-}"
after="${2:-HEAD}"

if [ -z "$before" ] || [[ "$before" =~ ^0+$ ]] || ! git cat-file -e "${before}^{commit}" 2>/dev/null; then
  echo "No usable base commit; checking ${after} alone."
  range=(-1 "$after")
else
  range=("${before}..${after}")
fi

# Merges are skipped by parent count below, not with --no-merges: with -1, that flag would check
# the newest non-merge ancestor of a merge <after>, and that commit is not part of this push.
# Captured first so a bad range fails the script. Split in memory, because a here-string needs a
# temp file, and if the file cannot be created the loop reads nothing and passes.
log="$(git log --format='%H%x09%P%x09%s' "${range[@]}" --)"
set -f
# shellcheck disable=SC2206  # Split on newlines is the point; set -f stops globbing.
IFS=$'\n' lines=($log)
set +f
unset IFS

bad=0
count=0
for line in ${lines[@]+"${lines[@]}"}; do
  sha="${line%%$'\t'*}"
  rest="${line#*$'\t'}"
  parents="${rest%%$'\t'*}"
  subject="${rest#*$'\t'}"
  case "$parents" in *' '*) continue ;; esac
  count=$((count + 1))
  if subject_ok "$subject"; then
    continue
  fi
  bad=$((bad + 1))
  report "${sha:0:12} has subject \"${subject}\". ${hint}"
done

if [ "$bad" -gt 0 ]; then
  echo "${bad} of ${count} commit subject(s) do not match the required format."
  exit 1
fi
echo "All ${count} commit subject(s) match the required format."
