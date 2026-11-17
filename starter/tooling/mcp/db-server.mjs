#!/usr/bin/env node
// project-db MCP server: one `psql` tool, zero runtime dependencies.
//
// Speaks MCP over stdio (JSON-RPC 2.0, newline-delimited JSON). Written without the MCP SDK so it
// runs from any git worktree before an install. Nothing may ever reach stdout except JSON-RPC
// responses: every diagnostic goes to stderr, and psql's own output only ever reaches a response.
//
// Scoping comes from the task environment (../task-env.mjs), re-read on every call so `up` takes
// effect without restarting the server:
// - main checkout: the database the primary env file's URL names, on this machine only.
// - worktree: only its task's database, and only after `up` gave it one. Otherwise it refuses.
// Extra live targets are configured in db-targets.mjs.

import { spawn } from 'node:child_process'
import path from 'node:path'
import * as taskConfigModule from '../task-env.config.mjs'
import {
  assertTaskEnvironment,
  checkout,
  primaryEnvFile,
  readEnvFile,
  readLeases,
} from '../task-env.mjs'
import {
  databaseOf,
  extraTargets,
  KILL_GRACE_MS,
  MAX_OUTPUT_CHARS,
  psqlCommand,
  TIMEOUT_MS,
} from './db-targets.mjs'

// Imported code that logs must not corrupt the protocol stream.
console.log = console.info = console.debug = console.error

const HERE = import.meta.dirname
const SERVER_INFO = { name: 'project-db', version: '1.0.0' }
const SUPPORTED_PROTOCOL_VERSIONS = ['2025-06-18', '2025-03-26', '2024-11-05']
const FALLBACK_PROTOCOL_VERSION = '2024-11-05'

const taskConfig = taskConfigModule.default
// FILL: the primary env file's database URL key, used only when task-env.config.mjs has no
// `database` (with one, its urlKey wins).
const FALLBACK_URL_KEY = 'DATABASE_URL'
const urlKey = () => taskConfig.database?.urlKey ?? FALLBACK_URL_KEY
const isLocalUrl = (url) =>
  (taskConfig.database?.isLocalDatabaseUrl ?? taskConfigModule.isLocalDatabaseUrl)?.(url) ?? false
const nameOf = (url) => (taskConfig.database?.nameOf ?? databaseOf)(url)

const DATABASE_NAME = /^[A-Za-z0-9_]+$/
const CONNECT_META = /\\c(onnect)?\b/

const targetNames = ['local', ...extraTargets.map((t) => t.name)]

function toolDescription() {
  let text =
    "Run SQL against Postgres. Target `local` (default) is this checkout's own database: in the " +
    "main checkout, the one its env file names; in a worktree, only the task database `up` " +
    'created, and nothing before `up`. SQL is piped to psql stdin, so meta-commands (\\dt, \\d ' +
    `table) work. Output is capped at ${MAX_OUTPUT_CHARS} characters; use LIMIT.`
  for (const target of extraTargets) {
    text +=
      ` WARNING: target \`${target.name}\` is a LIVE, NON-LOCAL database (${target.description}). ` +
      'Writes and DDL there take effect immediately for everyone; say so before you use it.'
  }
  return text
}

const TOOLS = [
  {
    name: 'psql',
    description: toolDescription(),
    inputSchema: {
      type: 'object',
      properties: {
        sql: { type: 'string', description: 'SQL (or psql meta-commands) to run.' },
        target: {
          type: 'string',
          enum: targetNames,
          default: 'local',
          description:
            'local = this checkout’s database.' +
            extraTargets.map((t) => ` ${t.name} = LIVE: ${t.description}.`).join(''),
        },
        database: {
          type: 'string',
          description:
            "Database name. On local, defaults to the env file's; a worktree may use only its task database. On another target, defaults to the one its URL names.",
        },
      },
      required: ['sql'],
      additionalProperties: false,
    },
  },
]

/** This server's checkout. Outside git (a copied tree), it is the main checkout of its own root. */
function here() {
  try {
    return checkout(HERE)
  } catch {
    return { root: path.resolve(HERE, '../..'), commonDir: undefined, isWorktree: false }
  }
}

/**
 * The `local` connection for one call, read fresh so `up` takes effect without a restart.
 * @param {unknown} requested
 * @param {string} sql
 * @returns {{ url: string, database: unknown } | { error: string }}
 */
function resolveLocal(requested, sql) {
  const ctx = here()
  const envFile = path.join(ctx.root, primaryEnvFile())
  const env = readEnvFile(envFile)
  const url = env[urlKey()]
  const offMachine = `${urlKey()} in ${envFile} is not a database on this machine; the local target refuses it. Add a named target in tooling/mcp/db-targets.mjs to reach it.`

  if (!ctx.isWorktree) {
    if (!url) return { error: `${urlKey()} is not set in ${envFile}.` }
    if (!isLocalUrl(url)) return { error: offMachine }
    return { url, database: requested ?? nameOf(url) }
  }

  if (!taskConfig.database) {
    return {
      error:
        'task environments in this repo have no database (`database` is null in tooling/task-env.config.mjs), so a worktree has none of its own to query.',
    }
  }
  try {
    assertTaskEnvironment(ctx.root)
  } catch (err) {
    return { error: err instanceof Error ? err.message : String(err) }
  }
  const task = env[taskConfig.taskKey]
  let lease
  try {
    lease = readLeases(ctx.commonDir)[task]
  } catch (err) {
    return { error: `cannot read the task leases: ${err instanceof Error ? err.message : err}` }
  }
  if (!lease || lease.worktree !== ctx.root) {
    return { error: `task "${task}" has no lease for this worktree. Run \`node tooling/task-env.mjs up ${task}\`.` }
  }
  const own = lease.database
  if (!own) return { error: `task "${task}" runs client-only, so it has no database of its own.` }
  if (!url || nameOf(url) !== own) {
    return {
      error: `${urlKey()} in ${envFile} does not name this task's database, ${own}. Run \`node tooling/task-env.mjs up ${task}\` again.`,
    }
  }
  if (!isLocalUrl(url)) return { error: offMachine }
  if (requested !== undefined && requested !== own) {
    return { error: `this worktree may query only its task database, ${own}.` }
  }
  if (typeof sql === 'string' && CONNECT_META.test(sql)) {
    return { error: `this worktree may query only its task database, ${own}; \\connect is refused.` }
  }
  return { url, database: own }
}

/**
 * A named extra target's connection for one call.
 * @param {(typeof extraTargets)[number]} target
 * @param {unknown} requested
 * @returns {{ url: string, database: unknown, spawn?: Function } | { error: string }}
 */
function resolveExtra(target, requested) {
  const url = target.url?.()
  if (!url) return { error: `target "${target.name}" is not configured: ${target.missing ?? 'its url() returned nothing.'}` }
  let database = requested
  try {
    database ??= databaseOf(url)
  } catch {
    return { error: `target "${target.name}" has an unparseable URL.` }
  }
  return { url, database, spawn: target.spawn }
}

/**
 * Run psql with `sql` on stdin. On timeout, SIGINT first (psql sends the server a cancel request
 * for the running statement), then SIGKILL after a grace period.
 * @param {{ command: string, args: string[], env?: NodeJS.ProcessEnv }} argv
 * @param {string} sql
 * @returns {Promise<{ code: number, stdout: string, stderr: string, timedOut: boolean }>}
 */
function runPsql(argv, sql) {
  return new Promise((resolve) => {
    let child
    try {
      child = spawn(argv.command, argv.args, {
        stdio: ['pipe', 'pipe', 'pipe'],
        env: argv.env ?? process.env,
      })
    } catch (err) {
      resolve({ code: -1, stdout: '', stderr: `failed to spawn ${argv.command}: ${err}`, timedOut: false })
      return
    }

    let stdout = ''
    let stderr = ''
    let timedOut = false
    let settled = false
    let killTimer
    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')
    // Keep a little past the cap, so the truncation marker can say how much there was without
    // holding an unbounded result set in memory.
    const keep = (text, chunk) => (text.length > MAX_OUTPUT_CHARS * 4 ? text : text + chunk)
    child.stdout.on('data', (chunk) => (stdout = keep(stdout, chunk)))
    child.stderr.on('data', (chunk) => (stderr = keep(stderr, chunk)))

    const timer = setTimeout(() => {
      timedOut = true
      child.kill('SIGINT')
      killTimer = setTimeout(() => child.kill('SIGKILL'), KILL_GRACE_MS)
    }, TIMEOUT_MS)

    const finish = (code, extraStderr) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      clearTimeout(killTimer)
      resolve({ code: typeof code === 'number' ? code : -1, stdout, stderr: stderr + extraStderr, timedOut })
    }
    child.on('error', (err) => finish(-1, `\n${argv.command} failed: ${err.message}`))
    child.on('close', (code) => finish(code, ''))

    // EPIPE here means psql exited before reading all input; the close handler reports why.
    child.stdin.on('error', () => {})
    child.stdin.end(sql.endsWith('\n') ? sql : `${sql}\n`)
  })
}

/**
 * Cap `text`, keeping the head (headers and first rows are the useful part). stdout and stderr are
 * capped separately so a huge result can't hide the error.
 * @param {string} text
 */
function capOutput(text) {
  if (text.length <= MAX_OUTPUT_CHARS) return text
  const total = text.length > MAX_OUTPUT_CHARS * 4 ? `more than ${MAX_OUTPUT_CHARS * 4}` : String(text.length)
  return `${text.slice(0, MAX_OUTPUT_CHARS)}\n… [truncated: ${MAX_OUTPUT_CHARS} of ${total} characters shown; re-run with LIMIT or a narrower SELECT]`
}

/** @param {string} message */
const errorResult = (message) => ({ content: [{ type: 'text', text: message }], isError: true })

/** @param {unknown} args */
async function callPsqlTool(args) {
  const input = args && typeof args === 'object' ? /** @type {Record<string, unknown>} */ (args) : {}
  const { sql } = input
  const target = input.target ?? 'local'

  if (typeof sql !== 'string' || sql.trim() === '') {
    return errorResult('`sql` is required and must be a non-empty string.')
  }
  const extra = extraTargets.find((t) => t.name === target)
  if (target !== 'local' && !extra) {
    return errorResult(`Invalid target ${JSON.stringify(target)}: expected one of ${targetNames.join(', ')}.`)
  }
  const resolved = extra ? resolveExtra(extra, input.database) : resolveLocal(input.database, sql)
  if ('error' in resolved) return errorResult(resolved.error)
  const { url, database } = resolved
  if (typeof database !== 'string' || !DATABASE_NAME.test(database)) {
    return errorResult(`Invalid database ${JSON.stringify(database)}: must match ${DATABASE_NAME}.`)
  }

  const argv = resolved.spawn ? resolved.spawn(database, url) : psqlCommand(url, database)
  const result = await runPsql(argv, sql)

  if (result.timedOut) {
    const partial = result.stdout.trim()
    return errorResult(
      `psql timed out after ${TIMEOUT_MS / 1000}s on target "${target}" and was cancelled.` +
        (partial ? `\n\nPartial stdout:\n${capOutput(partial)}` : ''),
    )
  }
  const parts = []
  if (result.stdout.trim() !== '') parts.push(capOutput(result.stdout.trimEnd()))
  if (result.stderr.trim() !== '') parts.push(`stderr:\n${capOutput(result.stderr.trimEnd())}`)
  if (result.code !== 0) {
    parts.unshift(`psql exited with code ${result.code} (target: ${target}, database: ${database})`)
    return errorResult(parts.join('\n\n'))
  }
  return { content: [{ type: 'text', text: parts.length > 0 ? parts.join('\n\n') : '(no output)' }] }
}

// ---------------------------------------------------------------------------------------------
// JSON-RPC over stdio

/** @param {object} message */
const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`)

// EPIPE when the client goes away mid-write; nothing useful to do about it.
process.stdout.on('error', () => {})

/** @param {Record<string, any>} msg */
async function dispatch(msg) {
  const { id, method, params } = msg
  // Notifications (including notifications/initialized) never get a response.
  if (id === undefined || id === null) return null
  const reply = (result) => ({ jsonrpc: '2.0', id, result })

  switch (method) {
    case 'initialize': {
      const requested = params?.protocolVersion
      const protocolVersion = SUPPORTED_PROTOCOL_VERSIONS.includes(requested) ? requested : FALLBACK_PROTOCOL_VERSION
      return reply({ protocolVersion, capabilities: { tools: {} }, serverInfo: SERVER_INFO })
    }
    case 'ping':
      return reply({})
    case 'tools/list':
      return reply({ tools: TOOLS })
    case 'tools/call': {
      const name = params?.name
      if (name !== 'psql') return reply(errorResult(`Unknown tool ${JSON.stringify(name)}. Available: psql.`))
      return reply(await callPsqlTool(params.arguments))
    }
    default:
      return { jsonrpc: '2.0', id, error: { code: -32601, message: `Method not found: ${String(method)}` } }
  }
}

/** @param {any} msg */
async function safeDispatch(msg) {
  if (!msg || typeof msg !== 'object') {
    return { jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Invalid Request' } }
  }
  try {
    return await dispatch(msg)
  } catch (err) {
    process.stderr.write(`project-db: dispatch failed: ${err instanceof Error ? err.stack : err}\n`)
    if (msg.id === undefined || msg.id === null) return null
    const message = `Internal error: ${err instanceof Error ? err.message : String(err)}`
    return { jsonrpc: '2.0', id: msg.id, error: { code: -32603, message } }
  }
}

/** @param {string} line */
async function handleLine(line) {
  const trimmed = line.trim()
  if (trimmed === '') return
  let msg
  try {
    msg = JSON.parse(trimmed)
  } catch (err) {
    send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: `Parse error: ${err}` } })
    return
  }
  if (Array.isArray(msg)) {
    // JSON-RPC batch: reply only with the non-null responses.
    const responses = (await Promise.all(msg.map(safeDispatch))).filter(Boolean)
    if (responses.length > 0) send(responses)
    return
  }
  const response = await safeDispatch(msg)
  if (response) send(response)
}

let buffer = ''
/** @type {Set<Promise<void>>} */
const pending = new Set()

/**
 * Lines are handled concurrently: responses are id-matched and nothing is shared, so a slow query
 * must not block `tools/list` or a second query.
 * @param {string} line
 */
function schedule(line) {
  const p = handleLine(line)
    .catch((err) => process.stderr.write(`project-db: line handling failed: ${err}\n`))
    .finally(() => pending.delete(p))
  pending.add(p)
}

process.stdin.setEncoding('utf8')
process.stdin.on('data', (chunk) => {
  buffer += chunk
  for (let index = buffer.indexOf('\n'); index !== -1; index = buffer.indexOf('\n')) {
    schedule(buffer.slice(0, index))
    buffer = buffer.slice(index + 1)
  }
})
process.stdin.on('end', async () => {
  schedule(buffer)
  buffer = ''
  // Drain in-flight work and let the event loop end the process: process.exit() here would
  // truncate buffered stdout writes when stdout is a pipe.
  while (pending.size > 0) await Promise.all([...pending])
})
process.on('uncaughtException', (err) => {
  process.stderr.write(`project-db: uncaught: ${err instanceof Error ? err.stack : err}\n`)
})
