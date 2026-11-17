#!/usr/bin/env node
/**
 * `.mcp.json` (Claude Code) and `.codex/config.toml` (Codex) must declare the same MCP servers,
 * each with the same transport: `url` (HTTP) or `command` (stdio).
 *
 *   node tooling/check-mcp-parity.mjs [repo root]      # default: the git top-level of the cwd
 *
 * Refuses: a server in one file but not the other; a server whose transport differs; a server
 * entry with neither or both of url/command, or with an empty one.
 *
 * Why: Claude Code and Codex agents work in the same repo and should see the same tools. A server
 * added to one file only means one agent silently lacks a tool the docs tell it to use. And Codex
 * merges a project entry field by field into a global entry of the same name, so `url` on one side
 * and `command` on the other breaks its config load.
 *
 * Both files missing: nothing to compare, exit 0. One missing: an error (create it, even empty).
 * `.codex/config.toml` is read by a small TOML parser in this file (no dependencies). It handles
 * the TOML a config file uses: tables, array tables, dotted and quoted keys, all four string
 * kinds, numbers, booleans, dates, arrays and inline tables. Anything it cannot parse is an error
 * with a line number, never a silent skip, because a skipped table would hide a server.
 *
 * Exit: 0 match, 1 mismatch, 2 a file is missing or unparseable.
 * Self-test: tooling/test/checks.test.sh
 */
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// ---------------------------------------------------------------------------------------------
// Minimal TOML parser.

/** A TOML date/time, kept as text. Not a table. */
export class TomlDate {
  constructor(text) {
    this.text = text
  }
}

export function parseToml(text) {
  let i = 0
  let line = 1
  const root = {}
  // Tables created by a [header] (or [[header]]), and tables closed to redefinition.
  const explicit = new Set()
  const inline = new Set()
  let current = root

  const fail = (message) => {
    throw new Error(`.codex/config.toml line ${line}: ${message}`)
  }
  const peek = (n = 0) => text[i + n]
  const eat = (s) => {
    if (text.startsWith(s, i)) {
      for (const c of s) if (c === '\n') line++
      i += s.length
      return true
    }
    return false
  }
  const skipWs = () => {
    while (peek() === ' ' || peek() === '\t') i++
  }
  const skipComment = () => {
    if (peek() === '#') while (i < text.length && peek() !== '\n') i++
  }
  const endOfLine = () => {
    skipWs()
    skipComment()
    if (i < text.length && !eat('\n') && !eat('\r\n')) fail(`unexpected ${JSON.stringify(peek())}`)
  }
  /** Whitespace, newlines and comments, as allowed inside arrays. */
  const skipAll = () => {
    for (;;) {
      skipWs()
      skipComment()
      if (!eat('\n') && !eat('\r\n')) return
    }
  }

  const escapes = { b: '\b', t: '\t', n: '\n', f: '\f', r: '\r', '"': '"', '\\': '\\' }
  function basicString(multi) {
    let out = ''
    const close = multi ? '"""' : '"'
    if (multi && (eat('\r\n') || eat('\n'))) {
      /* A newline right after the opening quotes is trimmed. */
    }
    for (;;) {
      if (i >= text.length) fail('unterminated string')
      if (text.startsWith(close, i)) {
        // """ may be followed by up to two more quotes that belong to the string.
        if (multi) {
          let extra = 0
          while (text[i + 3 + extra] === '"' && extra < 2) extra++
          out += '"'.repeat(extra)
          i += 3 + extra
        } else i++
        return out
      }
      const c = peek()
      if (c === '\n') {
        if (!multi) fail('newline in a single-line string')
        line++
      }
      if (c === '\\') {
        const n = text[i + 1]
        if (escapes[n] !== undefined) {
          out += escapes[n]
          i += 2
        } else if (n === 'u' || n === 'U') {
          const len = n === 'u' ? 4 : 8
          const hex = text.slice(i + 2, i + 2 + len)
          if (!/^[0-9a-fA-F]+$/.test(hex) || hex.length !== len) fail('bad unicode escape')
          out += String.fromCodePoint(parseInt(hex, 16))
          i += 2 + len
        } else if (multi && /[ \t\r\n]/.test(n)) {
          // Line-ending backslash: drop it and all following whitespace.
          i++
          while (/[ \t\r\n]/.test(peek() ?? '')) {
            if (peek() === '\n') line++
            i++
          }
        } else fail(`bad escape \\${n}`)
        continue
      }
      out += c
      i++
    }
  }
  function literalString(multi) {
    const close = multi ? "'''" : "'"
    if (multi && (eat('\r\n') || eat('\n'))) {
      /* trimmed */
    }
    const end = text.indexOf(close, i)
    if (end === -1) fail('unterminated string')
    let stop = end
    if (multi) while (text[stop + 3] === "'" && stop - end < 2) stop++
    const out = text.slice(i, stop)
    if (!multi && out.includes('\n')) fail('newline in a single-line string')
    for (const c of out) if (c === '\n') line++
    i = stop + close.length
    return out
  }

  function key() {
    const parts = []
    for (;;) {
      skipWs()
      if (eat('"')) parts.push(basicString(false))
      else if (eat("'")) parts.push(literalString(false))
      else {
        const m = /^[A-Za-z0-9_-]+/.exec(text.slice(i, i + 256))
        if (!m) fail('expected a key')
        parts.push(m[0])
        i += m[0].length
      }
      skipWs()
      if (!eat('.')) return parts
    }
  }

  function value() {
    skipWs()
    if (eat('"""')) return basicString(true)
    if (eat('"')) return basicString(false)
    if (eat("'''")) return literalString(true)
    if (eat("'")) return literalString(false)
    if (eat('[')) {
      const arr = []
      for (;;) {
        skipAll()
        if (eat(']')) return arr
        arr.push(value())
        skipAll()
        if (eat(']')) return arr
        if (!eat(',')) fail('expected , or ] in an array')
      }
    }
    if (eat('{')) {
      const table = {}
      inline.add(table)
      skipWs()
      if (eat('}')) return table
      for (;;) {
        assign(table, key(), (() => {
          if (!eat('=')) fail('expected =')
          return value()
        })())
        skipWs()
        if (eat('}')) return table
        if (!eat(',')) fail('expected , or } in an inline table')
      }
    }
    const rest = text.slice(i, i + 64)
    const date = /^\d{4}-\d{2}-\d{2}(?:[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})?)?|^\d{2}:\d{2}:\d{2}(?:\.\d+)?/.exec(rest)
    if (date) {
      i += date[0].length
      return new TomlDate(date[0])
    }
    const m = /^(?:true|false|[+-]?(?:inf|nan)|0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+|[+-]?\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d[\d_]*)?)(?=[\s,\]}#]|$)/.exec(rest)
    if (!m) fail(`unparseable value starting ${JSON.stringify(rest.split('\n')[0])}`)
    i += m[0].length
    if (m[0] === 'true') return true
    if (m[0] === 'false') return false
    if (/inf$/.test(m[0])) return m[0].startsWith('-') ? -Infinity : Infinity
    if (/nan$/.test(m[0])) return NaN
    return Number(m[0].replace(/_/g, ''))
  }

  const isPlain = (v) => typeof v === 'object' && v !== null && !Array.isArray(v) && !(v instanceof TomlDate)

  /** Walk/create the tables named by parts[0..-1] under `base`, for dotted keys and headers. */
  function descend(base, parts, forHeader) {
    let t = base
    for (const part of parts) {
      if (!(part in t)) t[part] = {}
      let next = t[part]
      if (Array.isArray(next) && forHeader && next.length && isPlain(next.at(-1))) next = next.at(-1)
      if (!isPlain(next) || inline.has(next)) fail(`"${part}" is already a value, not a table`)
      t = next
    }
    return t
  }

  function assign(table, parts, v) {
    const t = descend(table, parts.slice(0, -1), false)
    const last = parts.at(-1)
    if (last in t) fail(`duplicate key "${parts.join('.')}"`)
    t[last] = v
  }

  while (i < text.length) {
    skipAll()
    if (i >= text.length) break
    if (eat('[[')) {
      const parts = key()
      if (!eat(']]')) fail('expected ]]')
      const parent = descend(root, parts.slice(0, -1), true)
      const last = parts.at(-1)
      if (!(last in parent)) parent[last] = []
      if (!Array.isArray(parent[last])) fail(`"${parts.join('.')}" is not an array of tables`)
      current = {}
      parent[last].push(current)
      endOfLine()
    } else if (eat('[')) {
      const parts = key()
      if (!eat(']')) fail('expected ]')
      const name = parts.join('\u0000')
      if (explicit.has(name)) fail(`table [${parts.join('.')}] defined twice`)
      explicit.add(name)
      current = descend(root, parts, true)
      endOfLine()
    } else {
      const parts = key()
      if (!eat('=')) fail('expected = after a key')
      assign(current, parts, value())
      endOfLine()
    }
  }
  return root
}

// ---------------------------------------------------------------------------------------------
// The comparison.

const TRANSPORTS = ['url', 'command']

const isTable = (value) =>
  typeof value === 'object' && value !== null && [Object.prototype, null].includes(Object.getPrototypeOf(value))

/** { transport } or { problem } for one server entry, from its own top-level keys only. */
function transportOf(entry, where) {
  if (!isTable(entry)) return { problem: `${where} is not a table` }
  const found = TRANSPORTS.filter((key) => key in entry)
  if (found.length !== 1) {
    return {
      problem: found.length === 0 ? `${where} declares neither url nor command` : `${where} declares both url and command`,
    }
  }
  const [transport] = found
  if (typeof entry[transport] !== 'string' || entry[transport].trim() === '') {
    return { problem: `${where} has a ${transport} that is not a non-empty string` }
  }
  return { transport }
}

function serversOf(servers, file) {
  if (servers === undefined) return new Map()
  if (!isTable(servers)) throw new Error(`${file}: the server list is not a table`)
  return new Map(Object.entries(servers).map(([name, entry]) => [name, transportOf(entry, `${file} server "${name}"`)]))
}

/** name -> { transport } or { problem }, from `.mcp.json`'s text. Throws on invalid JSON. */
export function claudeServers(text) {
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch (error) {
    throw new Error(`.mcp.json: ${error.message}`)
  }
  if (!isTable(parsed)) throw new Error('.mcp.json: the top level is not an object')
  return serversOf(parsed.mcpServers, '.mcp.json')
}

/** name -> { transport } or { problem }, from `.codex/config.toml`'s text. Throws on invalid TOML. */
export function codexServers(text) {
  return serversOf(parseToml(text).mcp_servers, '.codex/config.toml')
}

/** Every way the two lists differ, as sentences. Empty when they match. */
export function compareServers(claude, codex) {
  const problems = []
  for (const side of [claude, codex]) for (const entry of side.values()) if (entry.problem) problems.push(entry.problem)
  for (const name of claude.keys())
    if (!codex.has(name)) problems.push(`"${name}" is in .mcp.json but not .codex/config.toml`)
  for (const name of codex.keys())
    if (!claude.has(name)) problems.push(`"${name}" is in .codex/config.toml but not .mcp.json`)
  for (const [name, entry] of claude) {
    const other = codex.get(name)
    if (entry.transport && other?.transport && entry.transport !== other.transport) {
      problems.push(`"${name}" uses ${entry.transport} in .mcp.json but ${other.transport} in .codex/config.toml`)
    }
  }
  return problems
}

function main() {
  let root = process.argv[2]
  if (!root) root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim()
  root = resolve(root)
  const claudePath = join(root, '.mcp.json')
  const codexPath = join(root, '.codex/config.toml')
  const have = [existsSync(claudePath), existsSync(codexPath)]
  if (!have[0] && !have[1]) {
    console.log('[mcp-parity] OK: neither .mcp.json nor .codex/config.toml exists; nothing to compare.')
    return 0
  }
  let problems
  try {
    if (!have[0]) throw new Error('.mcp.json is missing, but .codex/config.toml exists. Create it (e.g. {"mcpServers": {}}).')
    if (!have[1]) throw new Error('.codex/config.toml is missing, but .mcp.json exists. Create it (it may be empty).')
    problems = compareServers(claudeServers(readFileSync(claudePath, 'utf8')), codexServers(readFileSync(codexPath, 'utf8')))
  } catch (error) {
    console.error(`[mcp-parity] can't read the MCP configs: ${error.message}`)
    return 2
  }
  if (problems.length > 0) {
    console.error('[mcp-parity] .mcp.json and .codex/config.toml disagree:')
    for (const problem of problems) console.error(`  ${problem}`)
    console.error('Declare each server in both files, with the same transport (url or command).')
    return 1
  }
  console.log('[mcp-parity] OK: .mcp.json and .codex/config.toml declare the same servers.')
  return 0
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main()
