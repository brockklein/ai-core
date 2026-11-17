#!/usr/bin/env node
/**
 * Fails on a relative Markdown link whose target file or directory does not exist.
 *
 *   node tooling/check-markdown-links.mjs              # every tracked *.md, against the working tree
 *   node tooling/check-markdown-links.mjs --staged     # staged *.md, against the index (pre-commit)
 *   node tooling/check-markdown-links.mjs a.md b.md    # these files, against the working tree
 *
 * Why: agents navigate the repo by following links in AGENTS.md, skills and docs. A link to a
 * moved or deleted file sends them hunting, or worse, to a stale copy, and nobody notices until
 * an agent gets lost. A rename that forgets its incoming links is the usual cause.
 *
 * Checked: inline links and images `[t](path)`, `![a](<path with spaces>)`, and reference
 * definitions `[r]: path`. A `#fragment` or `?query` is dropped; only the file must exist.
 * Percent-encoding is decoded when it decodes cleanly.
 * Ignored: fenced code blocks, inline code spans, HTML comments, anything with a URL scheme
 * (https:, mailto:, ...), root-relative `/paths`, and anchor-only `#links`. Indented (4-space) code
 * blocks are NOT recognised, because telling them from nested list content needs a full parser;
 * fence code you want ignored.
 *
 * --staged reads the index, so a commit must be self-contained: a link to a file that exists only
 * untracked in the working tree fails. It reports broken links in the staged Markdown files, plus
 * links anywhere in indexed Markdown that point at a path this commit deletes or renames away, but
 * not older breakage in files the commit does not touch.
 *
 * Exit: 0 clean, 1 broken links, 2 usage or git error.
 * Self-test: tooling/test/checks.test.sh
 */
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const git = (cwd, ...args) =>
  execFileSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 })
const gitList = (cwd, ...args) => git(cwd, ...args).split('\0').filter(Boolean)

/** Same length and same line breaks, so offsets and line numbers survive blanking. */
const blank = (text) => text.replace(/[^\n]/g, ' ')

/** Blank out the parts of a Markdown document that cannot hold a real link. */
export function stripNonLinks(text) {
  // HTML comments first: they can span lines and contain fences.
  let out = text.replace(/<!--[\s\S]*?(?:-->|$)/g, blank)
  // Fenced code blocks: a fence of 3+ ` or ~, closed by a fence of the same char and >= length.
  const lines = out.split('\n')
  let fence = null
  for (let i = 0; i < lines.length; i++) {
    const m = /^ {0,3}(`{3,}|~{3,})/.exec(lines[i])
    if (fence) {
      if (m && m[1][0] === fence[0] && m[1].length >= fence.length && /^ {0,3}[`~]+\s*$/.test(lines[i]))
        fence = null
      lines[i] = blank(lines[i])
    } else if (m && !(m[1][0] === '`' && lines[i].slice(m.index + m[0].length).includes('`'))) {
      fence = m[1]
      lines[i] = blank(lines[i])
    }
  }
  out = lines.join('\n')
  // Inline code spans: a run of N backticks closed by the next run of exactly N, within one
  // paragraph (a span never crosses a blank line).
  out = out.replace(/(?<!`)(`+)(?!`)(?:(?!\n[ \t]*\n)[\s\S])*?(?<!`)\1(?!`)/g, blank)
  return out
}

/** Read one link destination starting at text[i]. Returns { dest } or null. */
function readDestination(text, i) {
  while (text[i] === ' ' || text[i] === '\t') i++
  if (text[i] === '<') {
    const end = text.indexOf('>', i + 1)
    if (end === -1 || text.slice(i + 1, end).includes('\n')) return null
    return { dest: text.slice(i + 1, end) }
  }
  let depth = 0
  let j = i
  for (; j < text.length; j++) {
    const c = text[j]
    if (c === '\\' && j + 1 < text.length) {
      j++
      continue
    }
    if (/\s/.test(c)) break
    if (c === '(') depth++
    else if (c === ')') {
      if (depth === 0) break
      depth--
    }
  }
  return j > i ? { dest: text.slice(i, j).replace(/\\(.)/g, '$1') } : null
}

const lineOf = (text, offset) => text.slice(0, offset).split('\n').length

/** Relative link targets in a Markdown document: [{ path, line }]. */
export function relativeLinks(text) {
  const clean = stripNonLinks(text)
  const found = []
  // Inline links and images: `](` not escaped.
  for (const m of clean.matchAll(/(?<!\\)\]\(/g)) {
    const d = readDestination(clean, m.index + 2)
    if (d) found.push({ dest: d.dest, line: lineOf(clean, m.index) })
  }
  // Reference definitions: `[label]: dest` at the start of a line.
  for (const m of clean.matchAll(/^ {0,3}\[(?:[^\]\\\n]|\\.)+\]:[ \t]*/gm)) {
    const d = readDestination(clean, m.index + m[0].length)
    if (d) found.push({ dest: d.dest, line: lineOf(clean, m.index) })
  }
  const links = []
  for (const { dest, line } of found) {
    if (/^(?:[a-z][a-z\d+.-]*:|\/|#)/i.test(dest)) continue
    const path = dest.split(/[?#]/, 1)[0]
    if (!path) continue
    let decoded = path
    try {
      decoded = decodeURIComponent(path)
    } catch {
      /* A literal percent sign is a valid filename character. */
    }
    links.push({ path: decoded, raw: path, line })
  }
  return links.sort((a, b) => a.line - b.line)
}

/** A view of the repo: the working tree, or the index (--staged). */
function snapshot(root, staged) {
  if (!staged) {
    return {
      exists: (abs) => existsSync(abs),
      read: (file) => readFileSync(resolve(root, file), 'utf8'),
    }
  }
  const paths = new Set([resolve(root)])
  for (const file of gitList(root, 'ls-files', '--cached', '-z')) {
    let path = resolve(root, file)
    while (!paths.has(path)) {
      paths.add(path)
      path = dirname(path)
    }
  }
  return {
    exists: (abs) => paths.has(abs.replace(/[/\\]+$/, '') || abs),
    read: (file) => git(root, 'show', `:${file}`),
  }
}

/**
 * Broken links. `files`: Markdown files to report on (repo-relative). `deleted`: repo-relative
 * paths removed by this change; links to them are reported from any of `scanAlso` too.
 */
export function brokenLinks(root, files, { staged = false, deleted = [], scanAlso = [] } = {}) {
  const view = snapshot(root, staged)
  const reportAll = new Set(files)
  const gone = new Set(deleted.map((file) => resolve(root, file)))
  const failures = []
  for (const file of [...new Set([...files, ...(gone.size ? scanAlso : [])])]) {
    if (!view.exists(resolve(root, file))) continue
    for (const link of relativeLinks(view.read(file))) {
      let target = resolve(root, dirname(file), link.path)
      let ok = view.exists(target)
      if (!ok && link.raw !== link.path) {
        target = resolve(root, dirname(file), link.raw)
        ok = view.exists(target)
      }
      if (!ok && (reportAll.has(file) || gone.has(resolve(root, dirname(file), link.path)))) {
        failures.push(`${file}:${link.line}: missing relative link target ${link.raw}`)
      }
    }
  }
  return failures
}

function main(args) {
  const root = git(process.cwd(), 'rev-parse', '--show-toplevel').trim()
  const isMd = (file) => file.toLowerCase().endsWith('.md')
  if (args.includes('--help') || args.includes('-h')) {
    console.log('usage: check-markdown-links.mjs [--staged | <file.md>...]')
    return 0
  }
  if (args[0] === '--staged') {
    if (args.length > 1) throw new Error('--staged takes no file arguments')
    const status = gitList(root, 'diff', '--cached', '--name-status', '--no-renames', '-z')
    const changed = []
    const deleted = []
    for (let i = 0; i < status.length; i += 2) {
      if (status[i] === 'D') deleted.push(status[i + 1])
      else if (isMd(status[i + 1])) changed.push(status[i + 1])
    }
    const indexed = gitList(root, 'ls-files', '--cached', '-z').filter(isMd)
    const failures = brokenLinks(root, changed, { staged: true, deleted, scanAlso: indexed })
    return report(failures, `${changed.length} staged Markdown file(s), ${deleted.length} deletion(s)`)
  }
  for (const arg of args) if (arg.startsWith('-')) throw new Error(`unknown option ${arg}`)
  const files = args.length
    ? args.map((arg) => relative(root, resolve(arg)).split(sep).join('/'))
    : gitList(root, 'ls-files', '--cached', '-z').filter(isMd)
  for (const file of files) if (!existsSync(resolve(root, file))) throw new Error(`no such file: ${file}`)
  return report(brokenLinks(root, files), `${files.length} Markdown file(s)`)
}

function report(failures, scope) {
  for (const failure of failures) console.error(`[markdown-links] ${failure}`)
  if (failures.length) {
    console.error('[markdown-links] Fix the link, or restore the file it points at.')
    return 1
  }
  console.log(`[markdown-links] OK: no broken relative links (${scope}).`)
  return 0
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv.slice(2))
  } catch (error) {
    console.error(`[markdown-links] ${error.message}`)
    process.exitCode = 2
  }
}
