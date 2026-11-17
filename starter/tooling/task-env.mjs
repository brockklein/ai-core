#!/usr/bin/env node
/**
 * A worktree's own environment: its own ports, optionally its own copy of the main database, and
 * the dev services running on them, so several agents can run the app side by side, one per git
 * worktree, without taking each other's ports or migrating each other's data.
 *
 *   node tooling/task-env.mjs up <name> [--client-only]
 *       Gives this worktree the task <name> and (re)starts its services. Rerun it freely: it stops
 *       what it started, keeps the ports and database it already has, and starts again.
 *       --client-only starts only the services marked `client`, against the main checkout's other
 *       services, with no database.
 *   node tooling/task-env.mjs stop
 *       Stops what `up` started here; ports, database, and env stay for the next `up`. It signals a
 *       process group only while that group's leader still has the pid AND start time recorded in
 *       .task/pids. A group it can't prove is its own is listed, left alone, and the command fails.
 *   node tooling/task-env.mjs down <name>
 *       Stops the task, drops its database, returns the env files to the main checkout's values,
 *       releases its ports, and fails with a list of anything still there. It works from any
 *       checkout for a task whose worktree was deleted without `down`.
 *   node tooling/task-env.mjs list
 *       The tasks this repo has, from every worktree.
 *
 * Why a task needs its own database: a branch's migration applied to a shared database breaks every
 * other checkout, and test runs delete rows other checkouts rely on.
 *
 * State:
 *   <worktree>/.task/        pids (with start times), task.json (ports, mode), dev.log
 *   <git common dir>/task-env/leases.json   every task's ports, worktree, and database, so names
 *                                           and ports are unique across worktrees
 *   <git common dir>/task-env/lock          held by whichever up/stop/down is running
 *
 * Until `up` runs, a worktree's env files are copies of the main checkout's (worktree-setup.sh), so
 * they name the main checkout's ports and database. App code should call `assertTaskEnvironment`
 * (exported below) at startup, so nothing in a worktree reaches the main database by accident.
 *
 * Nothing here ever drops, renames, or writes the main checkout's database or env files.
 *
 * The project-specific settings are in task-env.config.mjs. Node >= 22, no dependencies; needs
 * git, ps, and lsof.
 */

import { spawn, spawnSync } from 'node:child_process'
import {
  closeSync,
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
  appendFileSync,
} from 'node:fs'
import { createServer } from 'node:net'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseEnv } from 'node:util'
import config from './task-env.config.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const USAGE = 'usage: task-env.mjs up <name> [--client-only] | stop | down <name> | list'
// The name becomes part of database names; 32 keeps `<main>_<name>_copying` under Postgres's 63.
const NAME_PATTERN = /^[a-z][a-z0-9_]{0,31}$/
const LOCK_WAIT_SECONDS = Number(process.env.TASK_ENV_LOCK_WAIT_SECONDS) || 600
const STOP_GRACE_SECONDS = 10
const DEFAULT_READY_SECONDS = 60

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

class TaskError extends Error {}
const fail = (message) => {
  throw new TaskError(message)
}

// ---------------------------------------------------------------------------------------------
// Where we are

const git = (cwd, ...args) => {
  const result = spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8' })
  if (result.status !== 0) fail(`git ${args.join(' ')} failed: ${result.stderr?.trim()}`)
  return result.stdout.trim()
}

/**
 * The checkout this script belongs to (not the shell's cwd, so running a worktree's copy always
 * acts on that worktree). Assumes a non-bare repo whose main checkout holds the common .git dir.
 */
export function checkout(from = HERE) {
  const root = realpathSync(git(from, 'rev-parse', '--show-toplevel'))
  const commonDir = realpathSync(
    git(from, 'rev-parse', '--path-format=absolute', '--git-common-dir'),
  )
  const main = path.dirname(commonDir)
  return { root, main, commonDir, isWorktree: root !== main }
}

/** Every checkout git still knows about and that still exists on disk. */
export function worktrees(root) {
  return git(root, 'worktree', 'list', '--porcelain')
    .split('\n')
    .filter((line) => line.startsWith('worktree '))
    .map((line) => line.slice('worktree '.length))
    .filter((dir) => existsSync(dir))
    .map((dir) => realpathSync(dir))
}

export const isInside = (dir, parent) => dir === parent || dir.startsWith(parent + path.sep)

// ---------------------------------------------------------------------------------------------
// Env files

export const primaryEnvFile = () => config.envFiles[0]

export const readEnvFile = (file) =>
  existsSync(file) ? parseEnv(readFileSync(file, 'utf8')) : {}

/** The port a value names: a bare number or a URL's port. */
export const portOf = (value) => {
  if (/^\d+$/.test(value ?? '')) return Number(value)
  try {
    return Number(new URL(value).port) || undefined
  } catch {
    return undefined
  }
}

/** A service's port as `root`'s env files say, or its default. */
export function servicePort(root, service) {
  const [file, keys] = Object.entries(service.env ?? {})[0] ?? []
  if (!file) return undefined
  const key = Object.keys(keys)[0]
  return portOf(readEnvFile(path.join(root, file))[key]) ?? service.defaultPort
}

// Accepts what Node's parser and dotenv accept, including `export KEY=` lines.
const ENV_LINE = /^\s*(?:export\s+)?([A-Za-z_][\w.-]*)\s*=(.*)$/

const formatValue = (key, value) => {
  if (/^[\w@%+=:,./-]*$/.test(value)) return value
  if (!/["\\\n]/.test(value)) return `"${value}"`
  fail(`cannot write ${key}: its value needs quoting this script doesn't do.`)
}

/**
 * Rewrites the given keys line by line, so comments and order survive. `null` removes a key. Every
 * assignment of a key changes, so a duplicate further down can't keep the old value, and the result
 * is parsed back to prove it says what was meant.
 */
export function rewriteEnv(text, updates) {
  const pending = new Map(Object.entries(updates))
  const seen = new Set()
  const out = []
  for (const line of text.split(/\r?\n/)) {
    const match = line.trimStart().startsWith('#') ? null : ENV_LINE.exec(line)
    if (!match || !pending.has(match[1])) {
      out.push(line)
      continue
    }
    const key = match[1]
    const raw = match[2].trim()
    const quote = /^["'`]/.exec(raw)?.[0]
    // Replacing only the first line of a multi-line value would leave the rest as garbage.
    if (quote && raw.indexOf(quote, 1) === -1) fail(`${key} spans lines; refusing to rewrite it.`)
    seen.add(key)
    const value = pending.get(key)
    if (value !== null) out.push(`${key}=${formatValue(key, value)}`)
  }
  while (out.length && out[out.length - 1] === '') out.pop()
  for (const [key, value] of pending) {
    if (!seen.has(key) && value !== null) out.push(`${key}=${formatValue(key, value)}`)
  }
  const result = `${out.join('\n')}\n`
  const parsed = parseEnv(result)
  for (const [key, value] of pending) {
    if ((parsed[key] ?? null) !== value) fail(`${key} did not read back as written; not saving.`)
  }
  return result
}

const lexists = (file) => {
  try {
    lstatSync(file)
    return true
  } catch {
    return false
  }
}

/** A reader, or a crash, sees the old file or the new one, never half of either. */
function writeAtomic(file, text) {
  if (lexists(file) && lstatSync(file).isSymbolicLink()) {
    // Writing through it would change the file it points to, likely the main checkout's.
    fail(`${file} is a symlink; give this worktree its own copy.`)
  }
  mkdirSync(path.dirname(file), { recursive: true })
  const temp = `${file}.tmp-${process.pid}`
  writeFileSync(temp, text, existsSync(file) ? { mode: statSync(file).mode } : {})
  renameSync(temp, file)
}

/**
 * Refuses an env file that is a symlink, or whose real path (every parent directory resolved
 * through symlinks) lies outside the worktree: writing there would change another checkout's file,
 * most likely the main checkout's. A path that doesn't exist yet is judged by its nearest existing
 * parent, since `up` creates the rest inside it.
 */
function assertEnvDestinations(root, rels) {
  for (const rel of rels) {
    const file = path.resolve(root, rel)
    if (lexists(file) && lstatSync(file).isSymbolicLink()) {
      fail(`${rel} is a symlink; give this worktree its own copy.`)
    }
    let existing = file
    const rest = []
    while (!lexists(existing)) {
      rest.unshift(path.basename(existing))
      existing = path.dirname(existing)
    }
    let real
    try {
      real = path.join(realpathSync(existing), ...rest)
    } catch {
      fail(`${rel} leads through a broken symlink; give this worktree its own copy.`)
    }
    if (!isInside(real, root)) {
      fail(`${rel} resolves to ${real}, outside this worktree; give this worktree its own copy.`)
    }
  }
}

/** Every env file `up` or `down` may write. */
const envDestinations = () => [...new Set([...config.envFiles, ...Object.keys(managedKeys())])]

function updateEnvFiles(root, updatesByFile) {
  // Check every destination and compute every file first, so a refusal leaves all of them untouched.
  assertEnvDestinations(root, Object.keys(updatesByFile))
  const writes = Object.entries(updatesByFile).map(([rel, updates]) => {
    const file = path.join(root, rel)
    const text = existsSync(file) ? readFileSync(file, 'utf8') : ''
    return [file, rewriteEnv(text, updates)]
  })
  for (const [file, text] of writes) writeAtomic(file, text)
}

/** Every key `up` may write, per file: service ports, overrides, the task name, the database URL. */
function managedKeys() {
  const keys = {}
  const add = (file, key) => (keys[file] ??= new Set()).add(key)
  for (const service of config.services) {
    for (const [file, map] of Object.entries(service.env ?? {})) {
      for (const key of Object.keys(map)) add(file, key)
    }
  }
  for (const [file, map] of Object.entries(config.envOverrides ?? {})) {
    for (const key of Object.keys(map)) add(file, key)
  }
  add(primaryEnvFile(), config.taskKey)
  if (config.database) add(primaryEnvFile(), config.database.urlKey)
  return keys
}

// ---------------------------------------------------------------------------------------------
// Processes

/** Every live process. A fixed locale and zone, so start times compare across invocations. */
export function processTable() {
  const result = spawnSync('ps', ['-A', '-o', 'pid=,pgid=,stat=,lstart='], {
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: 'C', TZ: 'UTC' },
  })
  if (result.status !== 0) fail(`ps failed: ${result.stderr?.trim() || result.error}`)
  return result.stdout.split('\n').flatMap((line) => {
    const match = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.+?)\s*$/.exec(line)
    // A zombie has already exited and only waits for its parent to notice.
    if (!match || match[3].startsWith('Z')) return []
    return [{ pid: Number(match[1]), pgid: Number(match[2]), started: match[4] }]
  })
}

const startTimeOf = (pid, table = processTable()) => table.find((row) => row.pid === pid)?.started

/**
 * Whether `stop` may signal a recorded group.
 * - owned: the leader is alive with the recorded start time.
 * - reused: the pid belongs to a process started at another time. The kernel doesn't reuse a pid
 *   while a group of that id exists, so our group has ended and this process isn't ours.
 * - unproven: the leader has exited but the group has members. They could be ours or a stranger's
 *   whose leader reused the pid and exited; nothing here can tell which.
 * - gone: nothing of the group is left.
 */
export function classifyGroup(leader, table) {
  const current = table.find((row) => row.pid === leader.pid)
  if (current && current.started !== leader.started) return 'reused'
  if (!table.some((row) => row.pgid === leader.pid)) return 'gone'
  return current ? 'owned' : 'unproven'
}

const membersOf = (leaders, table) =>
  table.filter((row) => leaders.some(({ pid }) => pid === row.pgid))

const signal = (target, name) => {
  try {
    process.kill(target, name)
  } catch (err) {
    if (err.code !== 'ESRCH') throw err
  }
}

/**
 * Stops recorded groups and returns those it couldn't prove or couldn't stop. The proof is taken
 * again before SIGKILL. A shell or package-manager leader can exit on SIGTERM before its children;
 * those children get SIGKILL one by one, and only the ones seen in the group before signalling.
 */
async function stopGroups(leaders) {
  const table = processTable()
  for (const leader of leaders) {
    if (classifyGroup(leader, table) === 'reused') {
      console.log(`pid ${leader.pid} is now another process; left it alone.`)
    }
  }
  const owned = leaders.filter((leader) => classifyGroup(leader, table) === 'owned')
  const unproven = leaders.filter((leader) => classifyGroup(leader, table) === 'unproven')
  const seen = new Map(membersOf(owned, table).map((row) => [row.pid, row.started]))

  for (const leader of owned) signal(-leader.pid, 'SIGTERM')
  const waitForExit = async (seconds) => {
    for (let tick = 0; tick < seconds * 10; tick += 1) {
      if (membersOf(owned, processTable()).length === 0) return
      await sleep(100)
    }
  }
  await waitForExit(STOP_GRACE_SECONDS)

  const late = processTable()
  for (const leader of owned) {
    const state = classifyGroup(leader, late)
    if (state === 'owned') signal(-leader.pid, 'SIGKILL')
    if (state === 'unproven') {
      for (const member of membersOf([leader], late)) {
        if (seen.get(member.pid) === member.started) signal(member.pid, 'SIGKILL')
      }
    }
  }
  await waitForExit(5)

  const after = processTable()
  return [...owned, ...unproven].filter(
    (leader) => classifyGroup(leader, after) !== 'reused' && membersOf([leader], after).length > 0,
  )
}

const lsof = (args) => {
  const result = spawnSync('lsof', args, { encoding: 'utf8' })
  // lsof exits 1 when it finds nothing; only a failure to run it is an error.
  if (result.error) fail(`lsof failed: ${result.error.message}`)
  return result.stdout
}

/** Pids listening on a TCP port. On Linux, lsof sees only your own user's processes without root. */
export const listenersOn = (port) => [
  ...new Set(lsof(['-nP', `-iTCP:${port}`, '-sTCP:LISTEN', '-t']).split('\n').filter(Boolean).map(Number)),
]

export const listeningPorts = () =>
  new Set(
    lsof(['-nP', '-iTCP', '-sTCP:LISTEN', '-Fn'])
      .split('\n')
      .filter((line) => line.startsWith('n'))
      .map((line) => Number(/:(\d+)$/.exec(line)?.[1]))
      .filter(Boolean),
  )

export const cwdOf = (pid) =>
  lsof(['-a', '-d', 'cwd', '-p', String(pid), '-Fn'])
    .split('\n')
    .find((line) => line.startsWith('n'))
    ?.slice(1)

export function describePid(pid) {
  const name = spawnSync('ps', ['-o', 'comm=', '-p', String(pid)], { encoding: 'utf8' }).stdout?.trim()
  const cwd = cwdOf(pid)
  return `pid ${pid}${name ? ` (${path.basename(name)})` : ''}${cwd ? ` in ${cwd}` : ''}`
}

// lsof can miss a listener bound to one address that a wildcard bind on macOS slips past.
const canBind = (port) =>
  new Promise((resolve) => {
    const server = createServer()
    server.once('error', () => resolve(false))
    server.listen(port, () => server.close(() => resolve(true)))
  })

// ---------------------------------------------------------------------------------------------
// State: .task/ in the worktree, leases in the git common dir

const taskDir = (root) => path.join(root, '.task')
export const logPathOf = (root) => path.join(taskDir(root), 'dev.log')
const pidsPathOf = (root) => path.join(taskDir(root), 'pids')

/** `<pid> <service> <start time>` per line: the leader of each group `up` started. */
export function readLeaders(root) {
  const file = pidsPathOf(root)
  if (!existsSync(file)) return []
  return readFileSync(file, 'utf8')
    .split('\n')
    .flatMap((line) => {
      const match = /^(\d+) (\S+) (.+)$/.exec(line)
      return match && Number(match[1]) > 1
        ? [{ pid: Number(match[1]), service: match[2], started: match[3] }]
        : []
    })
}

const formatLeaders = (leaders) =>
  leaders.map(({ pid, service, started }) => `${pid} ${service} ${started}\n`).join('')

const leasesPath = (commonDir) => path.join(commonDir, 'task-env', 'leases.json')

export const readLeases = (commonDir) => {
  const file = leasesPath(commonDir)
  return existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : {}
}

const writeLeases = (commonDir, leases) =>
  writeAtomic(leasesPath(commonDir), `${JSON.stringify(leases, null, 2)}\n`)

/**
 * Records leaders in .task/pids and in the lease. The lease copy is what lets `down` stop a task
 * whose worktree was deleted with its .task/ inside it.
 */
function recordLeaders(ctx, name, leaders) {
  if (leaders.length) writeAtomic(pidsPathOf(ctx.root), formatLeaders(leaders))
  else rmSync(pidsPathOf(ctx.root), { force: true })
  const leases = readLeases(ctx.commonDir)
  if (name && leases[name]?.worktree === ctx.root) {
    leases[name].leaders = leaders
    writeLeases(ctx.commonDir, leases)
  }
}

const ownerOf = (dir) => {
  const match = /^(\d+) (.+)$/.exec(readFileSync(path.join(dir, 'owner'), 'utf8').trim())
  return match ? { pid: Number(match[1]), started: match[2] } : undefined
}
const sameOwner = (a, b) => Boolean(a && b && a.pid === b.pid && a.started === b.started)
const isDead = (owner) => startTimeOf(owner.pid) !== owner.started

/** Removes a directory by renaming it aside first, so only this exact directory goes. */
function removeDir(dir) {
  const grave = `${dir}.grave-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}`
  renameSync(dir, grave)
  rmSync(grave, { recursive: true, force: true })
}

/**
 * Creates `dir` holding an owner file naming `me`, and says whether this process made it. Written
 * aside and renamed into place, so the directory never exists without its owner file.
 */
function claimDir(dir, me) {
  const pending = `${dir}.pending-${process.pid}`
  rmSync(pending, { recursive: true, force: true })
  mkdirSync(pending)
  writeFileSync(path.join(pending, 'owner'), `${me.pid} ${me.started}\n`)
  try {
    renameSync(pending, dir)
    return true
  } catch (err) {
    rmSync(pending, { recursive: true, force: true })
    if (!['EEXIST', 'ENOTEMPTY', 'EPERM'].includes(err.code)) throw err
    return false
  }
}

/**
 * Removes `dir` if `stale`, an owner that has died, still holds it, and says whether it did.
 * Recoveries from one dead owner are serialized by a claim directory named for that owner, and the
 * owner is read again under the claim. So a waiter acting on what it saw earlier can't remove a
 * lock that another waiter has since recovered and taken. A claim whose own holder died is
 * recovered the same way.
 */
function evict(dir, stale, me) {
  const claim = `${dir}.evict-${stale.pid}-${stale.started.replace(/\W+/g, '_')}`
  if (!claimDir(claim, me)) {
    let holder
    try {
      holder = ownerOf(claim)
    } catch {
      return false // released between our attempt and this read
    }
    if (holder && isDead(holder)) evict(claim, holder, me)
    return false
  }
  try {
    let current
    try {
      current = ownerOf(dir)
    } catch {
      return false // already gone
    }
    if (!sameOwner(current, stale)) return false
    removeDir(dir)
    return true
  } finally {
    removeDir(claim)
  }
}

/**
 * Runs one up/stop/down at a time across every checkout of the repo, so a second `up` sees the
 * first one's ports. The lock is a directory created atomically, holding its owner's pid and start
 * time; a lock whose owner has died is recovered (see evict) and taken.
 */
async function withLock(ctx, work) {
  const lock = path.join(ctx.commonDir, 'task-env', 'lock')
  const me = { pid: process.pid, started: startTimeOf(process.pid) }
  mkdirSync(path.dirname(lock), { recursive: true })
  const deadline = Date.now() + LOCK_WAIT_SECONDS * 1000

  for (let announced = false; ; ) {
    if (claimDir(lock, me)) break
    let owner
    try {
      owner = ownerOf(lock)
    } catch {
      continue // released between our attempt and this read
    }
    if (owner && isDead(owner)) {
      // Lets the self-test hold one waiter between seeing a dead owner and recovering the lock.
      if (Number(process.env.TASK_ENV_TEST_STALE_PAUSE_MS)) {
        await sleep(Number(process.env.TASK_ENV_TEST_STALE_PAUSE_MS))
      }
      if (evict(lock, owner, me)) continue
      // Another waiter is recovering it, or already has; look again shortly.
      if (Date.now() > deadline) {
        fail(`could not recover the task-env lock (${lock}) from pid ${owner.pid}, which died holding it.`)
      }
      await sleep(50)
      continue
    }
    if (!announced) {
      console.log(`Waiting for another task-env command (pid ${owner?.pid})...`)
      announced = true
    }
    if (Date.now() > deadline) fail(`the task-env lock (${lock}) is still held by pid ${owner?.pid}.`)
    await sleep(200)
  }

  try {
    return await work()
  } finally {
    try {
      if (sameOwner(ownerOf(lock), me)) removeDir(lock)
    } catch {}
  }
}

// ---------------------------------------------------------------------------------------------
// Database

/**
 * Every database name a task uses, derived here so a hook can never be handed the main database.
 * Refuses a non-local URL instead of guessing that a remote server is safe to copy and drop on.
 */
function databasePlan(ctx, name) {
  const db = config.database
  if (!db) return null
  const mainFile = path.join(ctx.main, primaryEnvFile())
  const mainUrl = readEnvFile(mainFile)[db.urlKey]
  if (!mainUrl) fail(`${db.urlKey} is not set in ${mainFile}.`)
  if (!db.isLocalDatabaseUrl(mainUrl)) {
    fail(`${db.urlKey} in the main checkout is not on this machine; task databases are local only.`)
  }
  const mainName = db.nameOf(mainUrl)
  if (!/^[A-Za-z0-9_]+$/.test(mainName)) fail(`the main database name "${mainName}" is not usable.`)
  const target = `${mainName}_${name}`
  const copying = `${target}_copying`
  if (copying.length > (db.maxNameLength ?? 63)) fail(`"${name}" makes ${copying} too long.`)
  return { url: mainUrl, mainName, target, copying, taskUrl: db.withName(mainUrl, target) }
}

/** Every hook call goes through here, so the main database's name never reaches one. */
async function dbHook(plan, hook, args, names) {
  for (const name of names) {
    if (name === plan.mainName || !name.startsWith(`${plan.mainName}_`)) {
      fail(`refusing to ${hook} ${name}: it is not a task database.`)
    }
  }
  return config.database[hook]({ url: plan.url, ...args })
}

/** Copies under a temporary name and renames when done, so a cut-short copy never looks finished. */
async function copyDatabase(plan) {
  console.log(`Copying ${plan.mainName} to ${plan.target}...`)
  await dbHook(plan, 'drop', { name: plan.copying }, [plan.copying])
  // `source` is the one place the main name reaches a hook, and only as what is read from.
  await config.database.copy({ url: plan.url, source: plan.mainName, target: plan.copying })
  await dbHook(plan, 'rename', { from: plan.copying, to: plan.target }, [plan.copying, plan.target])
}

// ---------------------------------------------------------------------------------------------
// Commands

const assertName = (name) => {
  if (!name) fail(`name a task. ${USAGE}`)
  if (!NAME_PATTERN.test(name) || name.endsWith('_copying')) {
    fail(`"${name}" is not usable: start with a letter; lowercase, digits, and _; at most 32 long.`)
  }
}

/** The existing worktree, other than `root`, that holds task `name`, by lease or by its env file. */
function holderElsewhere(ctx, name, leases) {
  const others = worktrees(ctx.root).filter((dir) => dir !== ctx.root)
  const leased = leases[name]?.worktree
  if (leased && others.includes(leased)) return leased
  return others.find(
    (dir) => readEnvFile(path.join(dir, primaryEnvFile()))[config.taskKey] === name,
  )
}

async function startService(ctx, service, env) {
  const cwd = path.join(ctx.root, service.cwd ?? '.')
  if (!existsSync(cwd)) fail(`${service.name}: ${cwd} does not exist.`)
  const log = openSync(logPathOf(ctx.root), 'a')
  // detached: its own process group, so `stop` reaches everything it spawns and nothing else.
  const child = spawn('/bin/sh', ['-c', service.command], {
    cwd,
    detached: true,
    stdio: ['ignore', log, log],
    env,
  })
  closeSync(log)
  child.on('error', () => {})
  child.unref()
  const started = child.pid && startTimeOf(child.pid)
  if (!started) fail(`could not start ${service.name} (${service.command}).`)
  return { pid: child.pid, service: service.name, started }
}

/** Listening means ready. A listener outside the service's group means someone took its port. */
async function waitUntilListening(service, port, leader) {
  const seconds = service.readySeconds ?? DEFAULT_READY_SECONDS
  for (let tick = 0; tick < seconds * 4; tick += 1) {
    const table = processTable()
    const group = new Set(membersOf([leader], table).map((row) => row.pid))
    if (group.size === 0) fail(`${service.name} exited before listening on port ${port}.`)
    const holders = listenersOn(port)
    if (holders.some((pid) => group.has(pid))) return
    const stranger = holders.find((pid) => !group.has(pid))
    if (stranger) fail(`port ${port} was taken by ${describePid(stranger)}.`)
    await sleep(250)
  }
  fail(`${service.name} did not listen on port ${port} within ${seconds}s.`)
}

const tail = (file, lines) =>
  existsSync(file) ? readFileSync(file, 'utf8').split('\n').slice(-lines).join('\n') : ''

async function up(ctx, name, clientOnly) {
  assertName(name)
  if (!ctx.isWorktree) fail('run this in a worktree; the main checkout keeps the main stack.')
  // Before anything changes, so a refusal leaves no lease, database, or env file behind.
  assertEnvDestinations(ctx.root, envDestinations())
  const primary = path.join(ctx.root, primaryEnvFile())
  if (!existsSync(primary)) fail(`this worktree has no ${primaryEnvFile()}; run tooling/worktree-setup.sh.`)

  const leases = readLeases(ctx.commonDir)
  const current = readEnvFile(primary)[config.taskKey]
  if (current && current !== name) {
    fail(`this worktree is task "${current}"; run \`task-env.mjs down ${current}\` first.`)
  }
  const holder = holderElsewhere(ctx, name, leases)
  if (holder) fail(`task "${name}" belongs to the worktree at ${holder}; run it there.`)
  const lease = leases[name]
  if (lease && lease.worktree !== ctx.root) {
    fail(`task "${name}" was leased by ${lease.worktree}, which is gone. Run \`down ${name}\` first.`)
  }
  if (lease && Boolean(lease.clientOnly) !== clientOnly) {
    fail(`task "${name}" runs in another mode; run \`down ${name}\` first to change it.`)
  }

  const plan = clientOnly ? null : databasePlan(ctx, name)
  if (plan && !lease && (await dbHook(plan, 'exists', { name: plan.target }, [plan.target]))) {
    fail(`${plan.target} exists and no worktree holds it. Run \`down ${name}\` first, or pick another name.`)
  }

  // Before choosing ports, so this task's own listeners don't count as taken.
  const survivors = await stopGroups(readLeaders(ctx.root))
  if (survivors.length) {
    fail(`process groups ${survivors.map((l) => l.pid).join(', ')} are still running and are not provably this task's.`)
  }
  recordLeaders(ctx, name, [])

  // Ports: keep what this task had while it's still free; never take another lease's port, even a
  // stopped task's, so that task gets it back.
  const active = config.services.filter((service) => service.env && (!clientOnly || service.client))
  const leasedElsewhere = new Set(
    Object.entries(leases)
      .filter(([other]) => other !== name)
      .flatMap(([, l]) => Object.values(l.ports ?? {})),
  )
  const listening = listeningPorts()
  const pool = Array.from({ length: config.portPool.count }, (_, i) => config.portPool.first + i)
  const ports = {}
  const taken = new Set(leasedElsewhere)
  for (const service of active) {
    const candidates = [lease?.ports?.[service.name], ...pool].filter(
      (port) => port && pool.includes(port) && !taken.has(port),
    )
    let chosen
    for (const port of candidates) {
      if (!listening.has(port) && (await canBind(port))) {
        chosen = port
        break
      }
    }
    if (!chosen) fail(`no free port in ${pool[0]}-${pool.at(-1)}; down another task first.`)
    ports[service.name] = chosen
    taken.add(chosen)
  }

  // The lease goes first, so a failure below still holds the ports that the env files name.
  leases[name] = {
    worktree: ctx.root,
    ports,
    database: plan?.target ?? null,
    clientOnly,
    leaders: [],
    updated: new Date().toISOString(),
  }
  writeLeases(ctx.commonDir, leases)
  mkdirSync(taskDir(ctx.root), { recursive: true })
  writeAtomic(path.join(taskDir(ctx.root), 'task.json'), `${JSON.stringify({ name, clientOnly, ports }, null, 2)}\n`)

  const updates = {}
  const set = (file, key, value) => ((updates[file] ??= {})[key] = value)
  for (const service of active) {
    for (const [file, map] of Object.entries(service.env)) {
      for (const [key, build] of Object.entries(map)) set(file, key, build(ports[service.name]))
    }
  }
  for (const [file, map] of Object.entries(config.envOverrides ?? {})) {
    for (const [key, value] of Object.entries(map)) set(file, key, value)
  }
  set(primaryEnvFile(), config.taskKey, name)
  if (plan) set(primaryEnvFile(), config.database.urlKey, plan.taskUrl)
  updateEnvFiles(ctx.root, updates)

  if (plan && !(await dbHook(plan, 'exists', { name: plan.target }, [plan.target]))) {
    await copyDatabase(plan)
  }

  // Each service's own environment, so two services can use the same key (PORT) from different
  // files. Later wins: the shell, envOverrides, the task key and database URL, every key `up` wrote
  // to an env file the service names, then the service's own keys. The env files win over the
  // shell, since an exported PORT would otherwise move a service.
  const envFor = (service) => {
    const env = { ...process.env }
    for (const map of Object.values(config.envOverrides ?? {})) Object.assign(env, map)
    env[config.taskKey] = name
    if (plan) env[config.database.urlKey] = plan.taskUrl
    const own = Object.entries(service.env ?? {})
    for (const [file] of own) Object.assign(env, updates[file])
    for (const [file, map] of own) {
      for (const key of Object.keys(map)) env[key] = updates[file][key]
    }
    return env
  }

  const logPath = logPathOf(ctx.root)
  appendFileSync(logPath, `--- task-env up ${name} at ${new Date().toISOString()} ---\n`)
  const leaders = []
  try {
    for (const service of config.services) {
      if (clientOnly && !service.client) continue
      leaders.push(await startService(ctx, service, envFor(service)))
      recordLeaders(ctx, name, leaders)
    }
    for (const service of active) {
      await waitUntilListening(service, ports[service.name], leaders.find((l) => l.service === service.name))
    }
  } catch (err) {
    const left = await stopGroups(leaders)
    recordLeaders(ctx, name, left)
    const stopped = left.length ? `Could not stop pids ${left.map((l) => l.pid).join(', ')}.` : 'Stopped what this run started.'
    fail(`${err.message} ${stopped} Ports and database are kept; rerun up, or run down. The end of ${logPath}:\n${tail(logPath, 30)}`)
  }

  console.log(`Task ${name} is up${clientOnly ? ' (client only)' : ''}.`)
  for (const service of active) console.log(`  ${service.name}: http://localhost:${ports[service.name]}`)
  if (plan) console.log(`  database: ${plan.target}`)
  console.log(`  log: ${logPath}`)
}

async function stop(ctx) {
  if (!ctx.isWorktree) fail('run this in a worktree; task-env does not manage the main checkout.')
  const name = readEnvFile(path.join(ctx.root, primaryEnvFile()))[config.taskKey]
  const survivors = await stopGroups(readLeaders(ctx.root))
  recordLeaders(ctx, name, survivors)
  if (survivors.length) {
    const pids = membersOf(survivors, processTable()).map((row) => row.pid)
    fail(`process groups ${survivors.map((l) => l.pid).join(', ')} are still running (pid ${pids.join(', ')}); this could not stop them or prove they are this task's.`)
  }
  console.log('Stopped what this worktree started. `up <name>` starts it again.')
}

async function down(ctx, name) {
  assertName(name)
  const leases = readLeases(ctx.commonDir)
  const holder = holderElsewhere(ctx, name, leases)
  if (holder) fail(`task "${name}" belongs to the worktree at ${holder}; run down there.`)
  const lease = leases[name]
  const isHere =
    ctx.isWorktree && readEnvFile(path.join(ctx.root, primaryEnvFile()))[config.taskKey] === name
  // The worktree the task ran in; may no longer exist.
  const worktree = isHere ? ctx.root : lease?.worktree
  const clientOnly = Boolean(lease?.clientOnly)
  if (isHere) assertEnvDestinations(ctx.root, envDestinations())

  const problems = []
  const attempt = async (step) => {
    try {
      await step()
    } catch (err) {
      problems.push(err.message)
    }
  }

  let leaders = isHere ? readLeaders(ctx.root) : (lease?.leaders ?? [])
  await attempt(async () => {
    leaders = await stopGroups(leaders)
    if (isHere) recordLeaders(ctx, name, leaders)
  })

  let plan = null
  await attempt(async () => {
    plan = clientOnly ? null : databasePlan(ctx, name)
    if (plan) {
      await dbHook(plan, 'drop', { name: plan.copying }, [plan.copying])
      await dbHook(plan, 'drop', { name: plan.target }, [plan.target])
    }
  })

  // Look again rather than trusting the steps above.
  const leftovers = []
  await attempt(async () => {
    const table = processTable()
    const alive = membersOf(leaders, table).map((row) => row.pid)
    if (alive.length) leftovers.push(`processes ${alive.join(', ')} of this task`)
    if (plan) {
      for (const db of [plan.target, plan.copying]) {
        if (await dbHook(plan, 'exists', { name: db }, [db])) leftovers.push(`database ${db}`)
      }
    }
    // A port held from inside the task's worktree; a listener elsewhere took it after we let go.
    for (const port of Object.values(lease?.ports ?? {})) {
      for (const pid of listenersOn(port)) {
        const cwd = cwdOf(pid)
        if (worktree && cwd && isInside(cwd, worktree)) leftovers.push(`port ${port} held by ${describePid(pid)}`)
      }
    }
  })

  if (problems.length || leftovers.length) {
    for (const problem of problems) console.error(`task-env: ${problem}`)
    console.error(`task-env: ${name} is not fully down. Still here:`)
    for (const leftover of leftovers) console.error(`  ${leftover}`)
    // The lease and env stay, so running down again checks the same things.
    process.exitCode = 1
    return
  }

  if (isHere) {
    // Back to the main checkout's values, so app code refuses to run here until the next `up`.
    const updates = {}
    for (const [file, keys] of Object.entries(managedKeys())) {
      const main = readEnvFile(path.join(ctx.main, file))
      updates[file] = Object.fromEntries(
        [...keys].map((key) => [key, key === config.taskKey ? null : (main[key] ?? null)]),
      )
    }
    updateEnvFiles(ctx.root, updates)
    rmSync(taskDir(ctx.root), { recursive: true, force: true })
  }
  delete leases[name]
  writeLeases(ctx.commonDir, leases)
  console.log(`Task ${name} is down; nothing is left.`)
}

function list(ctx) {
  const leases = readLeases(ctx.commonDir)
  const names = Object.keys(leases).sort()
  if (!names.length) return console.log('No tasks.')
  const existing = new Set(worktrees(ctx.root))
  const table = processTable()
  for (const name of names) {
    const lease = leases[name]
    const running = (lease.leaders ?? []).some((l) => classifyGroup(l, table) === 'owned')
    const where = existing.has(lease.worktree) ? lease.worktree : `${lease.worktree} (gone; run down ${name})`
    const ports = Object.entries(lease.ports ?? {}).map(([s, p]) => `${s}:${p}`).join(' ')
    const db = lease.database ? ` db:${lease.database}` : ''
    const mode = lease.clientOnly ? ' client-only' : ''
    console.log(`${name}  ${running ? 'running' : 'stopped'}${mode}  ${ports}${db}  ${where}`)
  }
}

// ---------------------------------------------------------------------------------------------
// For app code

/**
 * Throws when called in a linked worktree that has no task yet: its env files still name the main
 * checkout's ports and database. Call it before your server or scripts read their env, e.g.
 *   import { assertTaskEnvironment } from '../tooling/task-env.mjs'
 *   assertTaskEnvironment(import.meta.dirname)
 * The main checkout, CI, and deployed copies have no linked worktree, so it does nothing there.
 */
export function assertTaskEnvironment(from = process.cwd()) {
  let ctx
  try {
    ctx = checkout(from)
  } catch {
    return // not a git checkout, e.g. a deployed build
  }
  if (!ctx.isWorktree) return
  if (!readEnvFile(path.join(ctx.root, primaryEnvFile()))[config.taskKey]) {
    throw new Error(
      `this worktree has no task environment, so its env still points at the main checkout. Run \`node tooling/task-env.mjs up <name>\` first.`,
    )
  }
}

async function main() {
  const [command, ...rest] = process.argv.slice(2).filter((arg) => arg !== '--')
  const clientOnly = command === 'up' && rest.includes('--client-only')
  const args = rest.filter((arg) => !(clientOnly && arg === '--client-only'))
  if (args.some((arg) => arg.startsWith('-'))) fail(USAGE)
  const ctx = checkout()
  if (command === 'up' && args.length <= 1) await withLock(ctx, () => up(ctx, args[0], clientOnly))
  else if (command === 'stop' && args.length === 0) await withLock(ctx, () => stop(ctx))
  else if (command === 'down' && args.length <= 1) await withLock(ctx, () => down(ctx, args[0]))
  else if (command === 'list' && args.length === 0) list(ctx)
  else fail(USAGE)
}

/** Whether this module is the script node was asked to run, compared by real path on both sides. */
const isMain = () => {
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
  } catch {
    return false
  }
}

if (isMain()) {
  main().catch((err) => {
    console.error(`task-env: ${err instanceof TaskError ? err.message : err.stack}`)
    process.exit(1)
  })
}
