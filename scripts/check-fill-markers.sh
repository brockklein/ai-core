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
# Exit: 0 when none remain, 1 when any remain, 2 on a usage error.
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

# grep exits 1 when nothing matches, which is the passing case here.
matches="$(grep -rnIE --exclude-dir=.git --exclude-dir=node_modules -- "$pattern" "$1" || true)"

if [ -z "$matches" ]; then
  echo "No FILL markers remain under $1."
  exit 0
fi

# grep prints path:line:text; add a space after the line number and trim leading indentation.
printf '%s\n' "$matches" | sed -E 's/^([^:]*:[0-9]+:)[[:space:]]*/\1 /'
count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
echo "${count} FILL marker(s) remain under $1." >&2
exit 1
