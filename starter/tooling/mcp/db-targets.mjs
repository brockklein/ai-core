/**
 * How the project-db MCP server reaches Postgres: timeouts, extra named targets, and the psql
 * invocation for a database URL. Side-effect-free, so tests and other tooling can import it without
 * starting the server.
 *
 * The `local` target is built in (db-server.mjs resolves it from this checkout's env file on every
 * call). Everything in `extraTargets` is NOT local: the tool description flags each one as live.
 */

/** How long the server waits for psql before it cancels it. */
export const TIMEOUT_MS = 60_000

/**
 * Postgres cancels any one statement after this long. A killed client does not reliably end its
 * query on the server, so this bound is what ends an abandoned one. It sits under TIMEOUT_MS so a
 * slow statement normally comes back as Postgres's own cancel error rather than a kill.
 */
export const STATEMENT_TIMEOUT_MS = TIMEOUT_MS - 5_000

/** libpq gives up on an unreachable server after this many seconds. */
export const CONNECT_TIMEOUT_SECONDS = 10

/** After SIGINT (psql sends the server a cancel request), how long before SIGKILL. */
export const KILL_GRACE_MS = 3_000

/** Hard cap on returned text per stream: an unbounded `select *` would flood an agent's context. */
export const MAX_OUTPUT_CHARS = 50_000

/**
 * Named targets beyond `local`, off by default. Each one is treated as LIVE: the tool description
 * says so in capitals, and nothing scopes it to a worktree. Add one only for a database your team
 * already reaches from a laptop, and prefer a read-only role.
 *
 * Shape:
 * - name: the `target` value the tool accepts ([a-z][a-z0-9_-]*, not `local`).
 * - description: one line the agent reads, e.g. 'staging: shared QA data'.
 * - url(): the connection URL, read at call time (from the shell env, a secret manager CLI, ...).
 *   Return undefined when it isn't configured; the call then fails with `missing`.
 * - missing: what to tell the agent when url() returns nothing.
 * - spawn(database, url): optional. Return { command, args, env } to reach the server some other
 *   way (an ssh hop, `docker exec`); psql must still read SQL from stdin. The default runs the
 *   local `psql` with the URL's parts in PG* env vars.
 */
// FILL: add your shared environments, or leave this empty. Example:
// {
//   name: 'staging',
//   description: 'staging: the shared QA environment, real test data',
//   url: () => process.env.STAGING_DATABASE_URL,
//   missing: 'export STAGING_DATABASE_URL (read-only role) in the shell that starts your agent.',
// },
export const extraTargets = []

/**
 * The PG* environment for one psql run against `url`, connecting to `database`. Parts go in the
 * environment, not argv, so a password never shows in `ps`. Inherited PG* variables are dropped
 * first: a stray PGHOST or PGSERVICE in the agent's shell must not redirect a `local` query.
 * @param {string} url
 * @param {string} database
 * @param {NodeJS.ProcessEnv} [base]
 */
export function psqlEnv(url, database, base = process.env) {
  const env = Object.fromEntries(Object.entries(base).filter(([key]) => !key.startsWith('PG')))
  const parsed = new URL(url)
  const set = (key, value) => {
    if (value) env[key] = value
  }
  set('PGHOST', parsed.hostname.replace(/^\[(.*)\]$/, '$1'))
  set('PGPORT', parsed.port)
  set('PGUSER', decodeURIComponent(parsed.username))
  set('PGPASSWORD', decodeURIComponent(parsed.password))
  set('PGSSLMODE', parsed.searchParams.get('sslmode') ?? '')
  env.PGDATABASE = database
  env.PGCONNECT_TIMEOUT = String(CONNECT_TIMEOUT_SECONDS)
  env.PGOPTIONS = `-c statement_timeout=${STATEMENT_TIMEOUT_MS}`
  env.PGAPPNAME = 'project-db-mcp'
  return env
}

/**
 * The psql invocation for `database` on the server `url` names. Never a shell string. -X skips
 * ~/.psqlrc so its settings can't change output or behavior; ON_ERROR_STOP makes a failing
 * statement fail the call.
 * @param {string} url
 * @param {string} database
 * @returns {{ command: string, args: string[], env: NodeJS.ProcessEnv }}
 */
export function psqlCommand(url, database) {
  return { command: 'psql', args: ['-X', '-v', 'ON_ERROR_STOP=1'], env: psqlEnv(url, database) }
}

/** The database a URL names. */
export const databaseOf = (url) => decodeURIComponent(new URL(url).pathname.slice(1))
