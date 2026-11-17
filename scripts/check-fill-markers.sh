#!/usr/bin/env bash
# Lists every placeholder left to fill in under a directory: the adoption "done when" check.
#
#   scripts/check-fill-markers.sh <dir>
#
# A placeholder is any text containing one of:
#   FILL:              # FILL: ... / // FILL: ... / <!-- FILL: ... --> / "Bash(FILL: ...)"
#   FILL (<note>):     e.g. <!-- FILL (optional): ... -->
#   [[FILL             e.g. [[FILL]] or [[FILL: project name]] in Markdown templates
# Prints file:line: text for each, skipping .git, node_modules and binary files.
#
# Exit: 0 when none remain, 1 when any remain, 2 on a usage error or when a file can't be read
# (an unread file could hold a marker, so it never counts as clean).
#
# Why: the starter's files are templates. A placeholder left behind reads to an agent as a real
# instruction ("run `[[FILL: task runner]] check`") or leaves a guardrail on a guessed default.
# Adoption is done when this prints nothing.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <dir>" >&2
  exit 2
fi

pattern='FILL( \([^)]*\))?:|\[\[FILL'

# grep exits 0 on a match, 1 on none (the passing case), and 2 when it could not read something.
rc=0
matches="$(grep -rnIE --exclude-dir=.git --exclude-dir=node_modules -- "$pattern" "$1")" || rc=$?
if [ "$rc" -gt 1 ]; then
  [ -n "$matches" ] && printf '%s\n' "$matches" | sed -E 's/^([^:]*:[0-9]+:)[[:space:]]*/\1 /'
  echo "error: could not read every file under $1 (grep's errors are above)." >&2
  exit 2
fi

if [ -z "$matches" ]; then
  echo "No FILL markers remain under $1."
  exit 0
fi

# grep prints path:line:text; add a space after the line number and trim leading indentation.
printf '%s\n' "$matches" | sed -E 's/^([^:]*:[0-9]+:)[[:space:]]*/\1 /'
count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
echo "${count} FILL marker(s) remain under $1." >&2
exit 1
