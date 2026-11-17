#!/usr/bin/env bash
# Self-test for the task environment tooling. Builds a throwaway repo with worktrees, gives it a
# config with one trivial HTTP service and a fake database (a directory per database, so the
# database path runs without a Postgres), and walks up -> status -> stop -> up -> down, plus the
# refusals and the cross-worktree guarantees.
#
# Usage: tooling/test/task-env.test.sh   (exits non-zero on any failure)
#
# It touches nothing outside its temp directory, and kills what it started on exit.
set -uo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
repo="$tmp/repo"
dbs="$tmp/dbs"
pool_first=$((47000 + (RANDOM % 40) * 20))
main_port=$((pool_first - 1))
passed=0
failed=0
strays=()

cleanup() {
  for pid in ${strays[@]+"${strays[@]}"}; do kill "$pid" 2>/dev/null; done
  # Anything the tests started runs from inside $tmp.
  for pid in $(lsof -t +D "$tmp" 2>/dev/null | sort -u); do kill -9 "$pid" 2>/dev/null; done
  chmod -R u+w "$tmp" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

ok() { passed=$((passed + 1)); echo "  ok    $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && sed 's/^/        /' <<<"$2"; }

# expect <0|1> <description> <grep pattern for output, or ''> <dir> <command...>
expect() {
  local want="$1" desc="$2" pattern="$3" dir="$4"
  shift 4
  local out status
  out="$(cd "$dir" && "$@" 2>&1)"
  status=$?
  if [ "$want" = 0 ] && [ "$status" != 0 ]; then bad "$desc (exit $status)" "$out"; return; fi
  if [ "$want" = 1 ] && [ "$status" = 0 ]; then bad "$desc (expected failure)" "$out"; return; fi
  if [ -n "$pattern" ] && ! grep -Eq -- "$pattern" <<<"$out"; then bad "$desc (no /$pattern/)" "$out"; return; fi
  ok "$desc"
}

check() { if eval "$2"; then ok "$1"; else bad "$1" "condition: $2"; fi; }

envval() { sed -n "s/^$2=//p" "$1/.env" | tail -1; }
answers() { node -e "fetch('http://127.0.0.1:$1').then(r=>r.text()).then(t=>{process.stdout.write(t)},()=>process.exit(1))"; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }

task() { node tooling/task-env.mjs "$@"; }
status() { node tooling/dev-status.mjs; }

# ---------------------------------------------------------------------------------------------
echo "Setting up $repo"
mkdir -p "$repo/tooling" "$dbs/main"
echo "precious" >"$dbs/main/rows"
cp "$here/task-env.mjs" "$here/dev-status.mjs" "$here/worktree-setup.sh" "$repo/tooling/"
cat >"$repo/tooling/task-env.config.mjs" <<'EOF'
import { cpSync, existsSync, renameSync, rmSync } from 'node:fs'
import path from 'node:path'

// A "database" is a directory beside the one the URL names: file:///…/dbs/main.
const dir = (url, name) => path.join(path.dirname(new URL(url).pathname), name)

export default {
  envFiles: ['.env'],
  taskKey: 'TASK_ENV',
  portPool: { first: POOL_FIRST, count: 20 },
  services: [
    {
      name: 'web',
      command:
        "exec node -e \"require('http').createServer((q, s) => s.end(process.cwd())).listen(process.env.PORT)\"",
      cwd: '.',
      env: { '.env': { PORT: String, PUBLIC_URL: (p) => `http://localhost:${p}` } },
      defaultPort: MAIN_PORT,
      client: true,
      readySeconds: 20,
    },
  ],
  envOverrides: { '.env': { MAILER: 'console' } },
  database: {
    urlKey: 'DATABASE_URL',
    isLocalDatabaseUrl: (url) => url.startsWith('file:///'),
    nameOf: (url) => path.basename(new URL(url).pathname),
    withName: (url, name) => new URL(name, url).toString(),
    exists: ({ url, name }) => existsSync(dir(url, name)),
    copy: ({ url, source, target }) => cpSync(dir(url, source), dir(url, target), { recursive: true }),
    rename: ({ url, from, to }) => renameSync(dir(url, from), dir(url, to)),
    drop: ({ url, name }) => rmSync(dir(url, name), { recursive: true, force: true }),
  },
}
EOF
sed -i.bak -e "s/POOL_FIRST/$pool_first/" -e "s/MAIN_PORT/$main_port/" "$repo/tooling/task-env.config.mjs"
rm "$repo/tooling/task-env.config.mjs.bak"

cat >"$repo/.env" <<EOF
# main checkout
PORT=$main_port
PUBLIC_URL=http://localhost:$main_port
DATABASE_URL=file://$dbs/main
MAILER=smtp
SECRET="kept as is"
EOF
printf '.env\n.task/\n' >"$repo/.gitignore"
main_env_before="$(cat "$repo/.env")"
(
  cd "$repo" && git init -q -b main && git add -A &&
    git -c user.name=t -c user.email=t@example.com commit -qm init &&
    for w in a b c d e; do git worktree add -q "$tmp/wt-$w" -b "$w"; done
) || { echo "could not build the test repo"; exit 1; }
a="$tmp/wt-a" b="$tmp/wt-b" c="$tmp/wt-c" d="$tmp/wt-d" e="$tmp/wt-e"

# ---------------------------------------------------------------------------------------------
echo "worktree-setup.sh"
expect 1 "refuses in the main checkout" "main checkout" "$repo" bash tooling/worktree-setup.sh
for w in "$a" "$b" "$c" "$d" "$e"; do (cd "$w" && bash tooling/worktree-setup.sh >/dev/null 2>&1); done
check "copies .env into the worktree" "[ \"\$(envval $a PORT)\" = $main_port ]"
expect 0 "keeps an existing file on rerun" "Keeping the existing .env" "$a" bash tooling/worktree-setup.sh

echo "guard for app code"
guard='import("./tooling/task-env.mjs").then(m => m.assertTaskEnvironment(process.cwd()))'
expect 1 "assertTaskEnvironment refuses a worktree before up" "no task environment" "$a" node -e "$guard"
expect 0 "assertTaskEnvironment allows the main checkout" "" "$repo" node -e "$guard"

# ---------------------------------------------------------------------------------------------
echo "up"
expect 1 "up refuses in the main checkout" "main checkout" "$repo" task up alpha
expect 1 "up refuses a bad name" "not usable" "$a" task up Alpha
expect 0 "up alpha in worktree a" "Task alpha is up" "$a" task up alpha
port_a="$(envval "$a" PORT)"
check "port comes from the pool" "[ $port_a -ge $pool_first ] && [ $port_a -lt $((pool_first + 20)) ]"
check "service answers from worktree a" "[ \"\$(answers $port_a)\" = \"$a\" ]"
check ".env names the task, its database, and the override" \
  "[ \"\$(envval $a TASK_ENV)\" = alpha ] && [ \"\$(envval $a DATABASE_URL)\" = file://$dbs/main_alpha ] && [ \"\$(envval $a MAILER)\" = console ]"
check "unmanaged keys and comments survive" "grep -q '^SECRET=\"kept as is\"' $a/.env && grep -q '^# main checkout' $a/.env"
check "database copied" "[ -f $dbs/main_alpha/rows ] && [ ! -e $dbs/main_alpha_copying ]"
check "pids recorded with start times" "grep -Eq '^[0-9]+ web .+' $a/.task/pids"
check "main checkout .env untouched" "[ \"\$(cat $repo/.env)\" = \"\$main_env_before\" ]"
expect 0 "assertTaskEnvironment allows the worktree after up" "" "$a" node -e "$guard"

echo "status"
expect 0 "status in a shows its own process" "web: running on port $port_a" "$a" status
expect 0 "status shows task and database" "Database: main_alpha" "$a" status
expect 0 "status in main names the free main port" "web: not running \\(port $main_port free\\)" "$repo" status
# Point worktree e's .env at a's port, as a stale copy would.
sed -i.bak "s/^PORT=.*/PORT=$port_a/" "$e/.env" && rm "$e/.env.bak"
expect 0 "status names another checkout holding the port" "port $port_a is held by pid [0-9]+ .*in $a" "$e" status

echo "uniqueness across worktrees"
expect 1 "another worktree can't take the same name" "belongs to the worktree at $a" "$b" task up alpha
expect 1 "down from another worktree is refused while a exists" "run down there" "$b" task down alpha
# c and d start at the same moment; the lock makes the second see the first's lease.
(cd "$c" && task up gamma >"$tmp/c.out" 2>&1; echo $? >"$tmp/c.status") &
(cd "$d" && task up delta >"$tmp/d.out" 2>&1; echo $? >"$tmp/d.status") &
wait
port_c="$(envval "$c" PORT)" port_d="$(envval "$d" PORT)"
check "concurrent ups both succeed" "[ \"\$(cat $tmp/c.status)\$(cat $tmp/d.status)\" = 00 ]"
check "concurrent ups get distinct ports" "[ $port_c != $port_d ] && [ $port_c != $port_a ] && [ $port_d != $port_a ]"
expect 0 "list shows every task" "alpha .*gamma|delta" "$repo" bash -c "node tooling/task-env.mjs list | tr '\n' ' '"

echo "lock"
lock="$repo/.git/task-env/lock"
sleep 300 &
holder=$!
disown "$holder"
strays+=("$holder")
mkdir "$lock"
echo "$holder $(LC_ALL=C TZ=UTC ps -o lstart= -p "$holder" | sed 's/^ *//;s/ *$//')" >"$lock/owner"
expect 1 "waits on a live holder, then gives up naming it" "still held by pid $holder" "$a" env TASK_ENV_LOCK_WAIT_SECONDS=1 node tooling/task-env.mjs stop
kill "$holder"
expect 0 "takes over a lock whose holder died" "Stopped" "$d" task stop
check "lock released after a command" "[ ! -e $lock ]"

# ---------------------------------------------------------------------------------------------
echo "stop"
sleep 300 &
stranger=$!
disown "$stranger"
strays+=("$stranger")
# A recorded pid that is now someone else's process (same pid, other start time).
echo "$stranger web Thu Jan  1 00:00:00 1970" >>"$a/.task/pids"
expect 0 "stop a" "Stopped" "$a" task stop
check "a's service is gone" "! listening $port_a"
check "a process whose pid was reused is left alone" "kill -0 $stranger"
check "pids file removed" "[ ! -e $a/.task/pids ]"
check "env, database, and lease kept" "[ \"\$(envval $a TASK_ENV)\" = alpha ] && [ -d $dbs/main_alpha ]"
expect 1 "stop refuses in the main checkout" "worktree" "$repo" task stop

echo "up again"
echo "edited" >"$dbs/main_alpha/rows"
expect 0 "rerun up alpha" "Task alpha is up" "$a" task up alpha
check "keeps its port" "[ \"\$(envval $a PORT)\" = $port_a ] && answers $port_a >/dev/null"
check "keeps its database (no recopy)" "[ \"\$(cat $dbs/main_alpha/rows)\" = edited ]"
expect 0 "rerun up while running restarts it" "Task alpha is up" "$a" task up alpha
expect 1 "up refuses a second name in the same worktree" "down alpha" "$a" task up other
expect 1 "up refuses switching mode" "another mode" "$a" task up alpha --client-only

echo "down"
expect 0 "down alpha" "nothing is left" "$a" task down alpha
check "service stopped" "! listening $port_a"
check "task database dropped, main kept" "[ ! -e $dbs/main_alpha ] && [ \"\$(cat $dbs/main/rows)\" = precious ]"
check ".env back to the main checkout's values" \
  "[ \"\$(envval $a PORT)\" = $main_port ] && [ \"\$(envval $a MAILER)\" = smtp ] && [ -z \"\$(envval $a TASK_ENV)\" ] && [ \"\$(envval $a DATABASE_URL)\" = file://$dbs/main ]"
check ".task removed" "[ ! -e $a/.task ]"
expect 1 "app guard refuses again after down" "no task environment" "$a" node -e "$guard"

echo "orphans and deleted worktrees"
mkdir "$dbs/main_orphan"
expect 1 "up refuses a database no worktree holds" "exists and no worktree holds it" "$a" task up orphan
expect 0 "down clears an orphan database" "nothing is left" "$a" task down orphan
check "orphan database gone" "[ ! -e $dbs/main_orphan ]"

expect 0 "up beta in worktree b" "Task beta is up" "$b" task up beta
port_b="$(envval "$b" PORT)"
(cd "$repo" && git worktree remove --force "$b")
check "beta keeps running after its worktree is deleted" "listening $port_b"
expect 1 "up elsewhere refuses a leased name whose worktree is gone" "is gone" "$a" task up beta
chmod 555 "$dbs"
expect 1 "down exits non-zero and lists what is left" "database main_beta" "$repo" task down beta
check "a failed down keeps the lease" "grep -q '\"beta\"' $repo/.git/task-env/leases.json"
chmod 755 "$dbs"
expect 0 "down from the main checkout clears the deleted worktree's task" "nothing is left" "$repo" task down beta
check "its processes and database are gone" "! listening $port_b && [ ! -e $dbs/main_beta ]"

echo "non-local database"
sed -i.bak "s#^DATABASE_URL=.*#DATABASE_URL=postgres://db.example.com/main#" "$repo/.env" && rm "$repo/.env.bak"
expect 1 "refuses a database that is not local" "not on this machine" "$a" task up zeta
sed -i.bak "s#^DATABASE_URL=.*#DATABASE_URL=file://$dbs/main#" "$repo/.env" && rm "$repo/.env.bak"

echo "client only"
expect 0 "up --client-only" "client only" "$a" task up kappa --client-only
check "no database for a client-only task" "[ ! -e $dbs/main_kappa ] && [ \"\$(envval $a DATABASE_URL)\" = file://$dbs/main ]"
expect 0 "down a client-only task" "nothing is left" "$a" task down kappa

(cd "$d" && task down delta >/dev/null 2>&1)
(cd "$c" && task down gamma >/dev/null 2>&1)
check "every lease released" "[ \"\$(node $repo/tooling/task-env.mjs list)\" = 'No tasks.' ]"
check "main database never touched" "[ \"\$(ls $dbs)\" = main ] && [ \"\$(cat $dbs/main/rows)\" = precious ]"

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
