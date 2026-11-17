#!/usr/bin/env node
/**
 * Reports this checkout's dev stack: for each service in task-env.config.mjs, the port this
 * checkout's env files assign it, and whether this checkout's process holds that port, nothing
 * does, or something else does (named by pid and working directory, so another worktree or another
 * project on the same port is obvious). Then the task, its database, and the log.
 *
 * A process counts as this checkout's when it's in a process group `up` recorded here, or when its
 * working directory is inside this checkout and not inside a worktree nested in it. That second
 * rule covers the main checkout, whose stack is started by hand rather than by `up`.
 *
 * Read-only, and always exits 0: it's a question, and agents call it to decide what to do next.
 *
 *   node tooling/dev-status.mjs
 */

import { existsSync, statSync } from 'node:fs'
import path from 'node:path'
import config from './task-env.config.mjs'
import {
  checkout,
  classifyGroup,
  cwdOf,
  describePid,
  isInside,
  listenersOn,
  logPathOf,
  primaryEnvFile,
  processTable,
  readEnvFile,
  readLeaders,
  servicePort,
  worktrees,
} from './task-env.mjs'

const attempt = (work, fallback) => {
  try {
    return work()
  } catch {
    return fallback
  }
}

function report() {
  const { root } = checkout()
  const nested = attempt(() => worktrees(root), []).filter((dir) => dir !== root && isInside(dir, root))
  const table = attempt(processTable, [])
  const leaders = readLeaders(root)
  const ownGroups = new Set(
    leaders.filter((leader) => classifyGroup(leader, table) === 'owned').map(({ pid }) => pid),
  )
  const pgidOf = (pid) => table.find((row) => row.pid === pid)?.pgid
  const isOwn = (pid) => {
    if (ownGroups.has(pgidOf(pid))) return true
    const cwd = attempt(() => cwdOf(pid), undefined)
    return Boolean(cwd) && isInside(cwd, root) && !nested.some((dir) => isInside(cwd, dir))
  }

  for (const service of config.services) {
    const port = servicePort(root, service)
    if (port === undefined) {
      const leader = leaders.find((l) => l.service === service.name)
      const running = leader && classifyGroup(leader, table) === 'owned'
      console.log(`${service.name}: ${running ? `running (pid ${leader.pid})` : 'not running'} (no port)`)
      continue
    }
    const holders = attempt(() => listenersOn(port), undefined)
    if (holders === undefined) {
      console.log(`${service.name}: unknown on port ${port} (lsof unavailable)`)
      continue
    }
    const own = holders.filter(isOwn)
    if (own.length) console.log(`${service.name}: running on port ${port} (pid ${own.join(', ')})`)
    else if (!holders.length) console.log(`${service.name}: not running (port ${port} free)`)
    else {
      const who = holders.map((pid) => attempt(() => describePid(pid), `pid ${pid}`))
      console.log(`${service.name}: not running here; port ${port} is held by ${who.join(', ')}`)
    }
  }

  const env = readEnvFile(path.join(root, primaryEnvFile()))
  const task = env[config.taskKey]
  console.log(`Task: ${task || 'none (`node tooling/task-env.mjs up <name>` in a worktree)'}`)
  if (config.database) {
    const url = env[config.database.urlKey]
    const name = attempt(() => config.database.nameOf(url), undefined)
    console.log(`Database: ${name || 'unknown'}`)
  }

  const log = logPathOf(root)
  if (!existsSync(log)) console.log('Log: none (`up` writes one)')
  else {
    const { size, mtimeMs } = statSync(log)
    console.log(`Log: ${log} (${size} bytes, written ${Math.round((Date.now() - mtimeMs) / 1000)}s ago)`)
  }
}

try {
  report()
} catch (err) {
  console.log(`dev-status: could not finish: ${err.message}`)
}
process.exit(0)
