/**
 * The project-specific half of the task environment (see task-env.mjs for the engine and the
 * commands). Every spot an adopter must decide carries a FILL marker comment. The defaults run as they
 * are: one service on a port from the pool, no database. Replace every marker, then delete the
 * marker comment itself, so a search for the marker in tooling/ comes back empty when you're done.
 *
 * Rules the engine holds you to, whatever you fill in:
 * - `up` refuses in the main checkout, and no hook below is asked to
 *   create, rename, or drop the main database: those names are derived (`<main database>_<task>`)
 *   and checked by the engine. The main database reaches a hook only as `copy`'s source.
 * - A database URL that `isLocalDatabaseUrl` rejects stops every command that would use it. The
 *   engine doesn't guess whether a remote server is "probably a dev box".
 * - Keys this file names are the only ones `up` rewrites, and `down` puts each back to the main
 *   checkout's value (or removes it, when the main checkout has none).
 * - Every env file named here must really live inside the worktree. `up` and `down` refuse, before
 *   changing anything, when one is a symlink or sits under a directory that resolves elsewhere.
 * - Each service starts with an environment of its own, so two services can each use PORT from
 *   their own env file. Later wins: the shell, every envOverrides value, the task key and database
 *   URL, every key `up` wrote to an env file the service names in `env`, then the service's own
 *   `env` keys.
 */

import { spawnSync } from 'node:child_process'

/**
 * The env files `up` rewrites, relative to the checkout root. The first one is the primary: it holds
 * `taskKey` and the database URL. worktree-setup.sh copies them from the main checkout, so before
 * `up` they still name the main checkout's ports.
 */
// FILL: list your gitignored env files; keep the one your server reads first.
export const envFiles = ['.env']

/**
 * The primary env file's key that names the task (empty in the main checkout and before `up`).
 * App code reads it through `assertTaskEnvironment` in task-env.mjs to refuse running in a worktree
 * whose env still points at the main checkout.
 */
export const taskKey = 'TASK_ENV'

/**
 * Where task ports come from. Pick a range nothing on your team's machines uses, and wide enough for
 * (services x parallel worktrees). Every worktree's ports are leased from this one pool, so two
 * worktrees never get the same port even while one is stopped.
 */
// FILL: a port range your machines leave free.
export const portPool = { first: 4100, count: 100 }

/**
 * The processes `up` starts, each in its own process group so `stop` can end everything it spawned
 * and nothing else.
 *
 * - name: a label for output and .task/pids.
 * - command: run with /bin/sh -c in `cwd`. It must stay in the foreground (no daemonizing), or
 *   `stop` loses track of it.
 * - cwd: relative to the checkout root.
 * - env: per env file, each key to write and how to build its value from the assigned port. The
 *   first key of the first file is the one dev-status reads back to find the service's port.
 *   Leave `env` out for a process with no port (a watcher); `up` then doesn't wait on it.
 * - defaultPort: the port the main checkout uses when its env file doesn't say.
 * - client: true for a service that `up --client-only` still starts. A client-only task runs these
 *   alone, against the main checkout's other services, and gets no database.
 * - readySeconds: how long `up` waits for the service to listen. A first boot that migrates a fresh
 *   database copy can take a while.
 */
export const services = [
  {
    name: 'web',
    // FILL: the command that starts this service in development, e.g. 'npm run dev'.
    command: 'npm run dev',
    // FILL: the package directory it runs from.
    cwd: '.',
    // FILL: every key that carries this service's port or URL, in every env file that has one.
    env: {
      '.env': {
        PORT: (port) => String(port),
        PUBLIC_URL: (port) => `http://localhost:${port}`,
      },
    },
    defaultPort: 3000,
    client: true,
    readySeconds: 120,
  },
  // FILL: one entry per service, e.g. an API whose URL the web app's env file also names:
  // { name: 'api', command: 'npm run dev', cwd: 'apps/api', defaultPort: 8000,
  //   env: { '.env': { API_PORT: String }, 'apps/web/.env.local': { VITE_API_URL: (p) => `http://localhost:${p}` } } },
]

/**
 * Values every task gets, whatever the main checkout has, per env file. Use it to turn off whatever
 * reaches the outside world: a task runs on a copy of real rows, and an agent's test run should not
 * email, charge, or push to anyone. `down` restores the main checkout's values.
 */
// FILL: switch off outside services (mail, payments, push, webhooks, analytics) for tasks.
export const envOverrides = {
  '.env': {
    // EMAIL_TRANSPORT: 'console',
    // STRIPE_SECRET_KEY: '',
  },
}

/** Whether a database URL names a server on this machine. Unparseable means no. */
export function isLocalDatabaseUrl(url) {
  try {
    const { protocol, hostname, searchParams } = new URL(url)
    return (
      ['postgres:', 'postgresql:'].includes(protocol) &&
      ['localhost', '127.0.0.1', '[::1]'].includes(hostname) &&
      // libpq lets ?host= or ?port= override the URL's own host, so only harmless options pass.
      [...searchParams.keys()].every((key) => key === 'sslmode')
    )
  } catch {
    return false
  }
}

const psql = (url, sql) => {
  const result = spawnSync('psql', [url, '-v', 'ON_ERROR_STOP=1', '-Atc', sql], { encoding: 'utf8' })
  if (result.status !== 0) throw new Error(`psql failed: ${result.stderr?.trim() || result.error}`)
  return result.stdout.trim()
}

const withDatabase = (url, name) => {
  const next = new URL(url)
  next.pathname = `/${name}`
  return next.toString()
}

/**
 * Database hooks for a local Postgres, reached with the `psql` on your PATH. Each hook gets the main
 * checkout's URL (to reach the server) and names the engine derived. The engine copies to
 * `<target>_copying` and renames once the copy is done, so an interrupted copy is never mistaken for
 * a finished one.
 *
 * `CREATE DATABASE ... TEMPLATE` is fast but refuses while anything is connected to the source.
 * If your main checkout's server stays connected while agents work, copy with
 * `pg_dump -Fc | pg_restore` instead; it works under live connections.
 */
export const postgresDatabase = {
  urlKey: 'DATABASE_URL',
  isLocalDatabaseUrl,
  nameOf: (url) => decodeURIComponent(new URL(url).pathname.slice(1)),
  withName: withDatabase,
  maxNameLength: 63,
  exists: ({ url, name }) =>
    psql(withDatabase(url, 'postgres'), `select 1 from pg_database where datname = '${name}'`) === '1',
  copy: ({ url, source, target }) =>
    psql(withDatabase(url, 'postgres'), `create database "${target}" template "${source}"`),
  rename: ({ url, from, to }) =>
    psql(withDatabase(url, 'postgres'), `alter database "${from}" rename to "${to}"`),
  drop: ({ url, name }) =>
    psql(withDatabase(url, 'postgres'), `drop database if exists "${name}" with (force)`),
}

/**
 * Each task's own database, or null for a project without one (or one whose tasks can share it
 * safely, which is rare: a branch's migration applied to a shared database breaks every other
 * checkout). With null, `up` only assigns ports.
 */
// FILL: set to postgresDatabase (after checking its urlKey and copy method), your own hooks with
// the same shape, or keep null.
export const database = null

export default { envFiles, taskKey, portPool, services, envOverrides, database }
