#!/usr/bin/env bash
# Self-test for the project-db MCP server. Builds a throwaway repo with a worktree, copies in the
# task environment and the server, puts a fake `psql` first on PATH (so no Postgres is needed), and
# drives the server over stdio: initialize, tools/list, tools/call. A fake database "exists" as a
# directory, so the real `task-env.mjs up` runs and writes the real lease.
#
# Usage: tooling/mcp/test/db-server.test.sh   (exits non-zero on any failure)
set -uo pipefail

tooling="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
repo="$tmp/repo"
wt="$tmp/wt-a"
bin="$tmp/bin"
dbs="$tmp/dbs"
passed=0
failed=0
trap 'rm -rf "$tmp"' EXIT

ok() { passed=$((passed + 1)); echo "  ok    $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && sed 's/^/        /' <<<"$2"; }

# ---------------------------------------------------------------------------------------------
# The fake psql: echoes what it was told to connect to, and reacts to keywords in the SQL.
mkdir -p "$bin" "$dbs/app"
cat >"$bin/psql" <<'EOF'
#!/bin/sh
sql="$(cat)"
case "$sql" in
  *BIG*) node -e 'process.stdout.write("x".repeat(120000))' ;;
  *FAIL*) echo 'ERROR:  relation "nope" does not exist' >&2; exit 3 ;;
  *) echo "db=$PGDATABASE host=$PGHOST port=$PGPORT user=$PGUSER pass=$PGPASSWORD opts=$PGOPTIONS args=$*"
     echo "sql=$sql"
     echo "psql chatter on stderr" >&2 ;;
esac
EOF
chmod +x "$bin/psql"

echo "Setting up $repo"
mkdir -p "$repo/tooling/mcp"
cp "$tooling/task-env.mjs" "$repo/tooling/"
cp "$tooling/mcp/db-server.mjs" "$tooling/mcp/db-targets.mjs" "$repo/tooling/mcp/"
cat >"$repo/tooling/task-env.config.mjs" <<EOF
import { existsSync, mkdirSync, renameSync, rmSync } from 'node:fs'
import path from 'node:path'

const dir = (name) => path.join('$dbs', name)
export const isLocalDatabaseUrl = (url) => ['localhost', '127.0.0.1'].includes(new URL(url).hostname)

export default {
  envFiles: ['.env'],
  taskKey: 'TASK_ENV',
  portPool: { first: 47900, count: 10 },
  services: [],
  envOverrides: {},
  database: {
    urlKey: 'DATABASE_URL',
    isLocalDatabaseUrl,
    nameOf: (url) => new URL(url).pathname.slice(1),
    withName: (url, name) => Object.assign(new URL(url), { pathname: '/' + name }).toString(),
    exists: ({ name }) => existsSync(dir(name)),
    copy: ({ target }) => mkdirSync(dir(target)),
    rename: ({ from, to }) => renameSync(dir(from), dir(to)),
    drop: ({ name }) => rmSync(dir(name), { recursive: true, force: true }),
  },
}
EOF
printf 'DATABASE_URL=postgres://dev:s3cret@localhost:5432/app\n' >"$repo/.env"
printf '.env\n.task/\n' >"$repo/.gitignore"
(
  cd "$repo" && git init -q -b main && git add -A &&
    git -c user.name=t -c user.email=t@example.com commit -qm init &&
    git worktree add -q "$wt" -b a && cp .env "$wt/.env"
) || { echo "could not build the test repo"; exit 1; }

# rpc <dir> <tools/call arguments JSON>: runs one server session and prints the call's result as
# "OK: <text>" or "ERR: <text>". Fails loudly if any stdout line is not a JSON-RPC message.
rpc() {
  local dir="$1" args="$2"
  {
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    echo "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"psql\",\"arguments\":$args}}"
  } | (cd "$dir" && PATH="$bin:$PATH" PGHOST=stray.example.com node tooling/mcp/db-server.mjs) \
    >"$tmp/stdout" 2>"$tmp/stderr"
  node -e '
    const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean)
    const byId = {}
    for (const line of lines) {
      let msg
      try { msg = JSON.parse(line) } catch { console.log("NONJSON: " + line); process.exit(0) }
      if (msg.jsonrpc !== "2.0") { console.log("NONRPC: " + line); process.exit(0) }
      byId[msg.id] = msg
    }
    if (lines.length !== 3) console.log(`LINES: ${lines.length}`)
    if (byId[1]?.result?.serverInfo?.name !== "project-db") console.log("NOINIT")
    if (byId[2]?.result?.tools?.[0]?.name !== "psql") console.log("NOTOOLS")
    const r = byId[3]?.result
    console.log((r?.isError ? "ERR: " : "OK: ") + (r?.content?.[0]?.text ?? JSON.stringify(byId[3])))
  ' "$tmp/stdout"
}

# expect <description> <grep -E pattern> <dir> <arguments JSON>
expect() {
  local out
  out="$(rpc "$3" "$4")"
  if grep -Eq -- "$2" <<<"$out" && ! grep -Eq '^(NONJSON|NONRPC|LINES|NOINIT|NOTOOLS)' <<<"$out"; then
    ok "$1"
  else
    bad "$1 (no /$2/)" "$out"
  fi
}

# ---------------------------------------------------------------------------------------------
echo "main checkout"
expect "initialize, tools/list, and a call use the env file's database" \
  '^OK: db=app host=localhost port=5432 user=dev pass=s3cret opts=-c statement_timeout=' "$repo" '{"sql":"select 1"}'
expect "an inherited PGHOST does not redirect local" 'host=localhost ' "$repo" '{"sql":"select 1"}'
expect "psql stderr comes back in the result" 'psql chatter on stderr' "$repo" '{"sql":"select 1"}'
expect "a meta-command reaches psql stdin" 'sql=\\dt' "$repo" '{"sql":"\\\\dt"}'
expect "the main checkout may name another local database" '^OK: db=other ' "$repo" '{"sql":"select 1","database":"other"}'
expect "a bad database name is refused" '^ERR: Invalid database' "$repo" '{"sql":"select 1","database":"x; drop"}'
expect "an unknown target is refused" '^ERR: Invalid target' "$repo" '{"sql":"select 1","target":"staging"}'
expect "a psql failure is an error with its stderr" '^ERR: psql exited with code 3' "$repo" '{"sql":"FAIL"}'

out="$(rpc "$repo" '{"sql":"BIG"}')"
if grep -q 'truncated: 50000 of 120000' <<<"$out" && [ "$(wc -c <<<"$out")" -lt 51000 ]; then
  ok "output is capped at 50000 characters"
else
  bad "output is capped" "$(head -c 300 <<<"$out")"
fi

printf 'DATABASE_URL=postgres://dev:s3cret@db.example.com:5432/app\n' >"$repo/.env"
expect "a non-local env URL is refused" '^ERR: .*not a database on this machine' "$repo" '{"sql":"select 1"}'
printf 'DATABASE_URL=postgres://dev:s3cret@localhost:5432/app\n' >"$repo/.env"

# ---------------------------------------------------------------------------------------------
echo "worktree before up"
expect "refuses without a task database" '^ERR: .*no task environment' "$wt" '{"sql":"select 1"}'

echo "worktree after up"
# One server across `up`: it must pick up the new env without a restart.
live="$(cd "$wt" && PATH="$bin:$PATH" node -e '
  const { spawn, spawnSync } = require("child_process")
  const server = spawn("node", ["tooling/mcp/db-server.mjs"], { stdio: ["pipe", "pipe", "inherit"] })
  const call = (id) => server.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call",
    params: { name: "psql", arguments: { sql: "select 1" } } }) + "\n")
  let out = "", upDone = false
  server.stdout.on("data", (chunk) => {
    out += chunk
    const lines = out.split("\n").filter(Boolean)
    if (lines.length === 1 && !upDone) {
      upDone = true
      const up = spawnSync("node", ["tooling/task-env.mjs", "up", "alpha"], { encoding: "utf8" })
      if (up.status !== 0) { console.log("UPFAILED " + up.stdout + up.stderr); process.exit(1) }
      call(2)
    } else if (lines.length === 2) {
      for (const line of lines) console.log(JSON.parse(line).result.content[0].text.split("\n")[0])
      server.stdin.end()
    }
  })
  call(1)
' 2>&1)"
if grep -q 'no task environment' <<<"$(sed -n 1p <<<"$live")" && grep -q '^db=app_alpha' <<<"$(sed -n 2p <<<"$live")"; then
  ok "task-env up alpha, picked up by a running server without a restart"
else
  bad "task-env up alpha, picked up by a running server without a restart" "$live"
fi
expect "uses its task database" '^OK: db=app_alpha host=localhost ' "$wt" '{"sql":"select 1"}'
expect "refuses another database" '^ERR: .*only its task database, app_alpha' "$wt" '{"sql":"select 1","database":"app"}'
expect "accepts its own database by name" '^OK: db=app_alpha ' "$wt" '{"sql":"select 1","database":"app_alpha"}'
expect "refuses \\connect" '^ERR: .*connect is refused' "$wt" '{"sql":"\\\\c app\nselect 1"}'
expect "allows \\copy" '^OK: db=app_alpha' "$wt" '{"sql":"\\\\copy t to stdout"}'

sed -i.bak 's#/app_alpha#/app#' "$wt/.env" && rm "$wt/.env.bak"
expect "refuses when the env URL drifts from the lease" "^ERR: .*does not name this task's database, app_alpha" "$wt" '{"sql":"select 1"}'
sed -i.bak 's#/app$#/app_alpha#' "$wt/.env" && rm "$wt/.env.bak"

if (cd "$wt" && node tooling/task-env.mjs down alpha >"$tmp/down.log" 2>&1); then ok "task-env down alpha"; else bad "task-env down alpha" "$(cat "$tmp/down.log")"; fi
expect "refuses again after down" '^ERR: .*no task environment' "$wt" '{"sql":"select 1"}'

# ---------------------------------------------------------------------------------------------
echo "extra targets"
cat >>"$repo/tooling/mcp/db-targets.mjs" <<'EOF2'
extraTargets.push({
  name: 'staging',
  description: 'staging: shared QA data',
  url: () => process.env.TEST_STAGING_URL,
  missing: 'set TEST_STAGING_URL.',
})
EOF2
out="$(echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | (cd "$repo" && node tooling/mcp/db-server.mjs 2>/dev/null))"
if grep -q 'target `staging` is a LIVE, NON-LOCAL database' <<<"$out" && grep -q '"enum":\["local","staging"\]' <<<"$out"; then
  ok "tools/list flags the extra target as live"
else
  bad "tools/list flags the extra target as live" "$out"
fi
expect "an unconfigured target says what is missing" '^ERR: target "staging" is not configured: set TEST_STAGING_URL' "$repo" '{"sql":"select 1","target":"staging"}'
export TEST_STAGING_URL='postgres://qa:pw@db.example.com:6543/qa'
expect "a configured target reaches its own server" '^OK: db=qa host=db.example.com port=6543 ' "$repo" '{"sql":"select 1","target":"staging"}'
unset TEST_STAGING_URL

# ---------------------------------------------------------------------------------------------
echo "protocol"
out="$( { echo 'not json'; echo '{"jsonrpc":"2.0","id":9,"method":"nope"}'; echo '{"jsonrpc":"2.0","id":10,"method":"ping"}'; } |
  (cd "$repo" && node tooling/mcp/db-server.mjs 2>/dev/null))"
if node -e 'const l=process.argv[1].split("\n");if(l.length!==3)process.exit(1);const m=l.map(JSON.parse);if(m[0].error?.code!==-32700||m[1].error?.code!==-32601||m[2].id!==10)process.exit(1)' "$out"; then
  ok "parse errors and unknown methods answer in JSON-RPC"
else
  bad "parse errors and unknown methods answer in JSON-RPC" "$out"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
