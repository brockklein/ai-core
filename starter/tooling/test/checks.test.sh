#!/usr/bin/env bash
# Self-test for the guardrail scripts in tooling/: real commits and pushes in temp repos, with a
# temp bare remote. Nothing here touches this repo, its hooks, or any real remote.
#
#   bash tooling/test/checks.test.sh
#
# Covers check-commit-subjects.sh, hooks/commit-msg, hooks/pre-push, check-markdown-links.mjs,
# check-mcp-parity.mjs, and (when present beside the starter) scripts/check-fill-markers.sh.
# The temp repos use a fixed repo.conf (below), not yours, so the test passes before you fill it in.
set -euo pipefail

tooling="$(cd "$(dirname "$0")/.." && pwd)"
fill_check="$(cd "$tooling/../.." && pwd)/scripts/check-fill-markers.sh"

# A hook exports these, and they would point every git call below at the real repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX ALLOW_PROTECTED_PUSH GITHUB_ACTIONS
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
zero=0000000000000000000000000000000000000000
fill='FILL'':' # split so this file is not itself a placeholder
failures=0

# expect <pass|fail> <name> <command...>
expect() {
  local want="$1" name="$2" got=pass
  shift 2
  "$@" >"$tmp/last.log" 2>&1 || got=fail
  if [ "$got" = "$want" ]; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name} (wanted ${want}, got ${got})"
    sed 's/^/       | /' "$tmp/last.log"
    failures=$((failures + 1))
  fi
}
same() {
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1 (got '$2', wanted '$3')"
    failures=$((failures + 1))
  fi
}
logged() { # logged <name> <text>: the last command's output contains <text>
  if grep -Fq -- "$2" "$tmp/last.log"; then echo "ok   - $1"; else
    echo "FAIL - $1 (output lacks: $2)"
    sed 's/^/       | /' "$tmp/last.log"
    failures=$((failures + 1))
  fi
}

# A repo with a copy of tooling/ and a known repo.conf. The check command is a stub that logs
# its run (and whether the hook's GIT_DIR leaked into it) and exits $CHECK_EXIT.
export CHECK_LOG="$tmp/check.log"
new_repo() { # new_repo <dir>
  rm -rf "$1"
  git init -q -b dev "$1"
  mkdir -p "$1/tooling"
  cp -R "$tooling/hooks" "$tooling/check-commit-subjects.sh" "$1/tooling/"
  cat >"$1/tooling/repo.conf" <<'CONF'
INTEGRATION_BRANCH="dev"
PROTECTED_BRANCHES="main release"
ALLOW_PROTECTED_PUSH_VAR="ALLOW_PROTECTED_PUSH"
REMOTE="origin"
ISSUE_KEY_RE='ABC-[0-9]+'
CONTEXT_PATHS=("**/*.md" ".agents/" ".claude/" ".codex/" ".mcp.json")
GENERATED_PATHS=("gen/")
CHECK_COMMAND='echo "check GIT_DIR=${GIT_DIR-<unset>}" >>"$CHECK_LOG"; exit "${CHECK_EXIT:-0}"'
CONF
}
ran_check() { # ran_check <name> <yes|no>: whether the last push ran CHECK_COMMAND
  local got=no
  [ -s "$CHECK_LOG" ] && got=yes
  same "$1" "$got" "$2"
  : >"$CHECK_LOG"
}
commit() { git commit -q --no-verify --allow-empty -m "$1"; }
fixture() { # fixture <path>: change one file and commit it
  mkdir -p "$(dirname "$1")"
  printf 'x\n' >>"$1"
  git add -- "$1"
  git commit -q --no-verify -m 'ABC-9: fixture'
}

echo '# check-commit-subjects.sh'
new_repo "$tmp/subj"
cd "$tmp/subj"
check=tooling/check-commit-subjects.sh
commit 'ABC-1: root'
subject_case() {
  local base
  base="$(git rev-parse HEAD)"
  commit "$2"
  expect "$1" "subject: $2" bash "$check" "$base" HEAD
  git reset -q --hard "$base"
}
subject_case pass 'ABC-49: run CI on dev'
subject_case pass 'ci: run on dev'
subject_case pass 'release-train: cut'
subject_case pass 'legacy_tools: add'
subject_case fail 'Run CI on dev'
subject_case fail 'XYZ-1: another project key'
subject_case fail 'ABC-1/ABC-2: two keys'
subject_case fail 'Ci: capital area'
subject_case fail 'ci:no space'
subject_case fail 'ci:  two spaces'
subject_case fail 'ABC-: no number'
subject_case fail 'Revert this without quotes'

commit 'bad subject'
base="$(git rev-parse HEAD)"
commit 'ABC-2: next push'
expect pass 'range: an earlier bad commit is outside the range' bash "$check" "$base" HEAD
commit 'another bad subject'
commit 'ABC-3: on top'
expect fail 'range: a bad commit under a good tip is inside the range' bash "$check" "$base" HEAD
expect pass 'before: all-zero checks the good head alone' bash "$check" "$zero" HEAD
expect pass 'before: unknown checks the good head alone' bash "$check" 1234567890123456789012345678901234567890 HEAD
expect pass 'before: empty checks the good head alone' bash "$check" '' HEAD
expect fail 'after: an unknown commit fails the script' bash "$check" HEAD no-such-ref

git reset -q --hard "$base"
git switch -q -c side
commit 'ABC-4: side'
git switch -q dev
commit 'ABC-5: main line'
git merge -q --no-ff -m 'merge side into dev' side
expect pass 'merge: exempt in a range' bash "$check" "$base" HEAD
expect pass 'merge: exempt as the head alone' bash "$check" "$zero" HEAD
git switch -q side
commit 'bad side subject'
git switch -q dev
git merge -q --no-ff -m 'merge side again' side
expect fail 'merge: a bad commit it brings in still fails' bash "$check" "$base" HEAD

git reset -q --hard "$base"
echo one >file && git add file && commit 'ABC-6: add file'
git revert --no-edit HEAD >/dev/null
expect pass 'revert: git-generated Revert "..."' bash "$check" "$base" HEAD
git revert --no-edit HEAD >/dev/null
expect pass 'revert: git-generated Reapply "..."' bash "$check" "$base" HEAD

msg="$tmp/msg"
printf 'ABC-2: subject\n\nbody with no prefix\n' >"$msg"
expect pass 'message: good subject' bash "$check" --message-file "$msg"
printf '\n# a comment\nABC-2: subject\n' >"$msg"
expect pass 'message: skips blank lines and comments' bash "$check" --message-file "$msg"
printf 'bad subject\n\nABC-2: only in the body\n' >"$msg"
expect fail 'message: bad subject' bash "$check" --message-file "$msg"
printf '# only a comment\n' >"$msg"
expect fail 'message: no subject' bash "$check" --message-file "$msg"

echo '# hooks/commit-msg'
git config core.hooksPath tooling/hooks
expect fail 'commit-msg: refuses a bad subject' git commit --allow-empty -m 'bad subject'
expect pass 'commit-msg: passes a good subject' git commit --allow-empty -m 'ABC-7: good'
git switch -q -c topic HEAD~1
commit 'ABC-8: topic'
git switch -q dev
expect pass 'commit-msg: a merge with any subject passes' git merge --no-ff -m 'merge topic' topic

echo '# hooks/pre-push'
git init -q --bare -b dev "$tmp/origin.git"
new_repo "$tmp/repo"
cd "$tmp/repo"
git remote add origin "$tmp/origin.git"
git add tooling
commit 'ABC-1: root'
git push -q --no-verify -u origin dev
git push -q --no-verify origin dev:main dev:release
git config core.hooksPath tooling/hooks
remote_sha() { git -C "$tmp/origin.git" rev-parse "refs/heads/$1"; }
allow() { ALLOW_PROTECTED_PUSH=1 "$@"; }

# Protected branches. HEAD has no diff against its upstream: the case where lefthook would skip a
# pre-push *command*; a plain hook still runs.
commit 'ABC-2: next'
git push -q --no-verify origin dev
sha="$(git rev-parse HEAD)"
main_before="$(remote_sha main)"
expect fail 'protected: refuses <sha>:main with no diff against upstream' git push origin "$sha:main"
logged 'protected: says why' 'refused an update of refs/heads/main'
expect fail 'protected: refuses a dry run' git push --dry-run origin "$sha:main"
expect fail 'protected: refuses a full ref' git push origin "$sha:refs/heads/main"
expect fail 'protected: refuses a force push' git push -f origin "$sha:main"
expect fail 'protected: refuses a delete' git push origin --delete main
expect fail 'protected: refuses the second protected branch' git push origin "$sha:release"
expect fail 'protected: refuses when main is one of several refs' git push origin "$sha:other" "$sha:main"
expect fail 'protected: a value other than 1 does not allow it' env ALLOW_PROTECTED_PUSH=true git push origin "$sha:main"
same 'protected: main did not move during the refusals' "$(remote_sha main)" "$main_before"
expect pass 'protected: the allow variable passes' allow git push origin "$sha:main"
same 'protected: main moved on the allowed push' "$(remote_sha main)" "$sha"
ran_check 'protected: a push to main runs no check' no
expect pass 'other refs: a tag named main is not the branch' git push origin "$sha:refs/tags/main"
expect pass 'other refs: a branch with main in its name' git push origin "$sha:refs/heads/main-fixes"

# Integration branch: subjects, then the check.
commit 'bad subject'
commit 'ABC-4: good tip'
expect fail 'integration: refuses a bad subject under a good tip' git push origin dev
ran_check 'integration: a bad subject refuses before the check runs' no
expect fail 'integration: the allow variable does not skip the subject check' allow git push origin dev
expect pass 'topic branch: subjects are not checked off the integration branch' git push origin HEAD:refs/heads/feature
git reset -q --hard origin/dev
echo change >file && git add file && commit 'ABC-5: real change'
expect fail 'integration: a failing check refuses the push' env CHECK_EXIT=1 git push origin dev
same 'integration: the refused push did not move dev' "$(remote_sha dev)" "$(git rev-parse HEAD~1)"
ran_check 'integration: the refused push ran the check' yes
expect pass 'integration: good subjects and a passing check pass' git push origin dev
same 'integration: the check ran once, without GIT_DIR' "$(cat "$CHECK_LOG")" 'check GIT_DIR=<unset>'
: >"$CHECK_LOG"
# The check reads the working tree, so it runs only when that tree is exactly the pushed commit.
commit 'ABC-6: pushed'
commit 'ABC-7: not pushed'
expect fail 'integration: refuses a commit other than HEAD' git push origin HEAD~1:dev
logged 'integration: and says to push HEAD' 'but HEAD is'
ran_check 'integration: a non-HEAD push runs no check' no
echo dirty >>file
expect fail 'integration: refuses uncommitted changes to a tracked file' git push origin HEAD:dev
logged 'integration: and names the file' ' M file'
ran_check 'integration: a dirty push runs no check' no
git checkout -q -- file
echo new >untracked.ts
expect fail 'integration: refuses an untracked file the check would read' git push origin HEAD:dev
logged 'integration: and names it' '?? untracked.ts'
rm untracked.ts
for flag in --assume-unchanged --skip-worktree; do
  echo hidden >>file
  git update-index "$flag" file
  expect fail "integration: refuses a file marked ${flag#--}" git push origin HEAD:dev
  logged "integration: and names the ${flag#--} file" '    file'
  ran_check "integration: a ${flag#--} push runs no check" no
  git update-index "--no${flag#-}" file
  git checkout -q -- file
done
echo ignored.out >.gitignore && git add .gitignore && commit 'ABC-7: ignore build output'
echo built >ignored.out
expect pass 'integration: an ignored file does not block the push' git push origin HEAD:dev
ran_check 'integration: and the check ran' yes
git worktree add -q "$tmp/linked" HEAD
git -C "$tmp/linked" commit -q --no-verify --allow-empty -m 'ABC-8: from a linked worktree'
expect pass 'linked worktree: an integration push passes' git -C "$tmp/linked" push origin HEAD:dev
same 'linked worktree: the check ran without GIT_DIR' "$(cat "$CHECK_LOG")" 'check GIT_DIR=<unset>'
: >"$CHECK_LOG"
git reset -q --hard origin/dev

# Context on the integration branch, and mixed topic branches.
base="$(git rev-parse HEAD)"
for file in 'README.md' 'docs/a [b].md' '.agents/skills/x.json' '.claude/settings.json' '.codex/config.toml' '.mcp.json'; do
  fixture "$file"
  expect fail "integration: refuses context $file" git push origin HEAD:dev
  logged 'integration: names the file and the context/<topic> route' 'context/<topic> branch'
  ran_check 'integration: context refuses before the check runs' no
  git reset -q --hard "$base"
done
fixture docs/reverted.md
git rm -q docs/reverted.md
commit 'ABC-9: revert context'
expect fail 'integration: refuses context changed then reverted within the range' git push origin HEAD:dev
git reset -q --hard "$base"
fixture docs/context.md
expect pass 'context branch: pure context passes' git push origin HEAD:refs/heads/context/pure
fixture src/code.ts
expect fail 'context branch: context plus code refuses' git push origin HEAD:refs/heads/context/mixed
logged 'mixed: names the context file' 'docs/context.md'
expect fail 'topic branch: context plus code refuses' git push origin HEAD:refs/heads/feature-mixed
git reset -q --hard "$base"
fixture src/code.ts
expect pass 'topic branch: pure code passes' git push origin HEAD:refs/heads/code-only
fixture gen/README.md
expect pass 'generated: a generated .md counts as code on a topic branch' git push origin HEAD:refs/heads/code-gen
expect pass 'generated: and on the integration branch' git push origin HEAD:dev
fixture gen/other.md
fixture docs/hand.md
expect fail 'generated: generated plus context is mixed' git push origin HEAD:refs/heads/gen-mixed
logged 'generated: lists only the hand-written context' 'docs/hand.md'
if grep -q 'gen/other.md' "$tmp/last.log"; then echo 'FAIL - generated: not listed as context'; failures=$((failures + 1)); else echo 'ok   - generated: not listed as context'; fi
git reset -q --hard origin/dev
base="$(git rev-parse HEAD)"
: >"$CHECK_LOG"

# Merges: reviewed context arriving from the remote parent passes; context made by the merge fails.
git switch -q -c context/merged
fixture docs/merged.md
git switch -q dev
git merge -q --no-ff -m 'merge context' context/merged
expect fail 'integration: refuses context from a local merge' git push origin HEAD:dev
git push -q --no-verify origin HEAD:dev # stands in for the reviewed PR merging on the host
git reset -q --hard "$base"
fixture src/local-before-pull.ts
git merge -q --no-ff -m 'merge origin dev into local code' origin/dev
expect pass 'integration: local code merged with reviewed remote context passes' git push origin HEAD:dev
git switch -q -c evil-side
fixture src/evil-side.ts
git switch -q dev
fixture src/evil-main.ts
git merge -q --no-ff --no-commit evil-side >/dev/null 2>&1
fixture docs/evil.md
expect fail 'integration: refuses context introduced by an evil merge' git push origin HEAD:dev
logged 'integration: the evil merge refusal names the file' 'docs/evil.md'
git reset -q --hard origin/dev
: >"$CHECK_LOG"

# Deletes and fail-closed cases, fed to the hook directly.
hook_ref() { printf '%s %s %s %s\n' HEAD "$1" "$2" "$3" | bash tooling/hooks/pre-push origin "$tmp/origin.git"; }
expect pass 'topic branch: a delete passes' git push origin --delete context/pure
fixture src/new.ts
expect fail 'integration: an unknown remote commit fails closed' hook_ref "$(git rev-parse HEAD)" refs/heads/dev 1111111111111111111111111111111111111111
logged 'integration: and says to fetch' 'git fetch origin'
git reset -q --hard origin/dev
tip="$(git rev-parse origin/dev)"
git update-ref -d refs/remotes/origin/dev
expect fail 'topic branch: a missing origin/dev fails closed' hook_ref "$tip" refs/heads/topic "$zero"
expect pass 'topic branch: a delete needs no origin/dev' hook_ref "$zero" refs/heads/topic "$tip"
git update-ref refs/remotes/origin/dev "$tip"
expect pass 'integration: a new remote branch checks only commits no remote has' hook_ref "$tip" refs/heads/dev "$zero"
git -C "$tmp/origin.git" symbolic-ref HEAD refs/heads/main
: >"$CHECK_LOG"
expect pass 'integration: a delete passes' git push origin --delete dev
ran_check 'integration: a delete runs no check' no

# An empty CHECK_COMMAND says it skipped.
git push -q --no-verify origin "$tip:refs/heads/dev"
sed -i.bak 's/^CHECK_COMMAND=.*/CHECK_COMMAND=""/' tooling/repo.conf
commit 'ABC-10: with no check'
expect pass 'integration: an empty CHECK_COMMAND passes' git push origin HEAD:dev
logged 'integration: and says no check ran' 'CHECK_COMMAND in tooling/repo.conf is empty'

echo '# check-markdown-links.mjs'
links="$tooling/check-markdown-links.mjs"
mkdir -p "$tmp/md" && cd "$tmp/md" && git init -q
mkdir -p docs/sub
printf 'x\n' >docs/a.md
printf 'y\n' >'a b.png'
printf 'z\n' >'100%.md'
printf 'target\n' >target.md
cat >ok.md <<'EOF'
`[code](missing1)` and ``a ` [x](missing2) ``

```md
[x](missing3)
```

~~~
[x](missing4)
~~~

<!-- [x](missing5)
-->

[x](docs/a.md#anchor) [x](https://example.com) [x](#local) [x](mailto:a@b) [abs](/etc/none)
![x](a%20b.png) ![y](<a b.png>) [d](docs/sub/) [d](docs) [p](100%.md) [q](100%25.md "title")
[ref][r] [up](docs/../target.md)

[r]: target.md "title"
EOF
cat >docs/bad.md <<'EOF'
# Bad

[fine](a.md)
[broken](missing.md#x)

[r]: ../gone.md
EOF
git add -A && commit 'ABC-1: base'
expect pass 'links: ignores code, comments, URLs, anchors; resolves encodings and dirs' node "$links" ok.md
expect fail 'links: explicit file with broken links fails' node "$links" docs/bad.md
logged 'links: reports file:line and target' 'docs/bad.md:4: missing relative link target missing.md'
logged 'links: reports reference definitions' 'docs/bad.md:6: missing relative link target ../gone.md'
expect fail 'links: all tracked files includes the broken one' node "$links"
ln -s "$links" "$tmp/links-link.mjs"
expect fail 'links: runs when invoked through a symlinked path' node "$tmp/links-link.mjs" docs/bad.md
git rm -q docs/bad.md && commit 'ABC-2: drop bad'
expect pass 'links: all tracked files, clean' node "$links"
expect fail 'links: a missing explicit file is an error' node "$links" nope.md
# --staged
printf '[new](docs/new.md)\n' >staged.md
printf 'new\n' >docs/new.md
git add staged.md
expect fail 'links --staged: a target only in the working tree fails' node "$links" --staged
git add docs/new.md
expect pass 'links --staged: an indexed target passes' node "$links" --staged
rm docs/new.md
expect pass 'links --staged: reads the index, not the working tree' node "$links" --staged
git checkout -q -- docs/new.md && commit 'ABC-3: staged'
git rm -q target.md
expect fail 'links --staged: deleting a target fails its untouched linkers' node "$links" --staged
logged 'links --staged: names the incoming link' 'ok.md:'
git reset -q --hard
printf '[old](missing-before.md)\n' >old-debt.md && git add old-debt.md && commit 'ABC-4: debt'
printf 'unrelated\n' >other.md && git add other.md
expect pass 'links --staged: leaves old breakage in untouched files alone' node "$links" --staged
git reset -q --hard

echo '# check-mcp-parity.mjs'
parity="$tooling/check-mcp-parity.mjs"
mcp() { # mcp <dir> <json> <toml>
  rm -rf "$1" && mkdir -p "$1/.codex"
  printf '%s\n' "$2" >"$1/.mcp.json"
  printf '%s\n' "$3" >"$1/.codex/config.toml"
}
good_json='{"mcpServers": {"docs": {"type": "http", "url": "https://example.com/mcp"}, "db": {"command": "npx", "args": ["-y", "db"]}}}'
good_toml='model = "x"

[mcp_servers.docs]
url = "https://example.com/mcp"
http_headers = { "X-Key" = "k" }

[mcp_servers.db]
command = "npx"
args = [
  "-y", # a comment
  "db",
]
env.FOO = "bar"'
mcp "$tmp/p1" "$good_json" "$good_toml"
expect pass 'mcp: matching servers pass' node "$parity" "$tmp/p1"
mcp "$tmp/p2" "$good_json" '[mcp_servers.docs]
command = "docs-server"

[mcp_servers.db]
command = "npx"'
expect fail 'mcp: a transport mismatch fails' node "$parity" "$tmp/p2"
logged 'mcp: names the mismatch' '"docs" uses url in .mcp.json but command in .codex/config.toml'
ln -s "$parity" "$tmp/parity-link.mjs"
expect fail 'mcp: runs when invoked through a symlinked path' node "$tmp/parity-link.mjs" "$tmp/p2"
mcp "$tmp/p3" '{"mcpServers": {"docs": {"url": "https://example.com/mcp"}}}' "$good_toml"
expect fail 'mcp: a server missing from .mcp.json fails' node "$parity" "$tmp/p3"
logged 'mcp: names the missing server' '"db" is in .codex/config.toml but not .mcp.json'
mcp "$tmp/p4" "$good_json" "$good_toml
[mcp_servers.extra]
url = \"https://example.com/x\""
expect fail 'mcp: a server missing from .codex/config.toml fails' node "$parity" "$tmp/p4"
mcp "$tmp/p5" '{"mcpServers": {"db": {"command": "npx", "url": "https://x"}}}' '[mcp_servers.db]
command = "npx"'
expect fail 'mcp: both url and command fails' node "$parity" "$tmp/p5"
mcp "$tmp/p6" "$good_json" "$good_toml
[mcp_servers.broken"
expect fail 'mcp: unparseable TOML fails loudly' node "$parity" "$tmp/p6"
logged 'mcp: with a line number' 'line 14'
mcp "$tmp/p7" "$good_json" '[mcp_servers]
docs = { url = "https://example.com/mcp" }
db.command = "npx"'
expect pass 'mcp: inline tables and dotted keys pass' node "$parity" "$tmp/p7"
mcp "$tmp/p8" '{"mcpServers": ' "$good_toml"
expect fail 'mcp: invalid JSON fails' node "$parity" "$tmp/p8"
mkdir -p "$tmp/p9"
expect pass 'mcp: neither file exists passes' node "$parity" "$tmp/p9"
printf '{"mcpServers": {}}\n' >"$tmp/p9/.mcp.json"
expect fail 'mcp: only one file exists fails' node "$parity" "$tmp/p9"

echo '# check-fill-markers.sh'
if [ -f "$fill_check" ]; then
  mkdir -p "$tmp/fill/sub" "$tmp/fill/node_modules" "$tmp/fill/.git"
  printf 'done\n' >"$tmp/fill/clean.txt"
  printf '# %s ignored\n' "$fill" >"$tmp/fill/node_modules/x"
  printf '# %s ignored\n' "$fill" >"$tmp/fill/.git/x"
  expect pass 'fill: no markers passes' bash "$fill_check" "$tmp/fill"
  printf 'a\n  # %s pick a branch\n' "$fill" >"$tmp/fill/sub/conf"
  printf '# [[%s]]\n' 'FI''LL' >"$tmp/fill/sub/doc.md"
  printf '<!-- %s (optional)%s a note -->\n' 'FILL' ':' >"$tmp/fill/opt.md"
  expect fail 'fill: a marker fails' bash "$fill_check" "$tmp/fill"
  logged 'fill: prints file:line: text' "$tmp/fill/sub/conf:2: # $fill pick a branch"
  logged 'fill: finds the double-bracket form' "$tmp/fill/sub/doc.md:1:"
  logged 'fill: finds the (optional) form' "$tmp/fill/opt.md:1:"
  if grep -q 'ignored' "$tmp/last.log"; then echo 'FAIL - fill: skips .git and node_modules'; failures=$((failures + 1)); else echo 'ok   - fill: skips .git and node_modules'; fi
  expect fail 'fill: a missing directory is a usage error' bash "$fill_check" "$tmp/nope"
  mkdir -p "$tmp/fill-locked"
  printf '# %s pick a branch\n' "$fill" >"$tmp/fill-locked/conf"
  chmod 000 "$tmp/fill-locked/conf"
  expect fail 'fill: a file it cannot read fails instead of passing' bash "$fill_check" "$tmp/fill-locked"
  logged 'fill: and says it could not read every file' 'could not read'
  chmod 644 "$tmp/fill-locked/conf"
else
  echo "skip - check-fill-markers.sh is not beside this starter (${fill_check})"
fi

if [ "$failures" -gt 0 ]; then
  echo "${failures} check(s) failed."
  exit 1
fi
echo "All checks passed."
