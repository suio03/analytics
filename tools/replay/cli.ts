#!/usr/bin/env node
/**
 * Session recordings from the admin API, read as text or watched in a local player.
 *
 *   replays list <site> [--days N] [--visitor ID] [--limit N]
 *   replays timeline <site> <session>
 *   replays scan <site> [--days N] [--limit N] [--has EVENT] [--json]
 *   replays play <site> <session>
 *
 * Needs PLAUSIBLE_URL and PLAUSIBLE_API_KEY (see docs/admin-cli.md).
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { execFile } from 'node:child_process'
import { type Extracted, extract, type Interaction, type RrwebEvent } from './extract.ts'
import { renderTimeline, targetText } from './render.ts'

interface Session {
  session_id: string
  visitor_id: string
  started_at: string
  ended_at: string
  loads: number
  events: number
  bytes: number
}

const base = (process.env.PLAUSIBLE_URL ?? '').replace(/\/$/, '')
const key = process.env.PLAUSIBLE_API_KEY ?? ''

function fail(msg: string): never {
  console.error(msg)
  process.exit(1)
}

async function api<T>(path: string, query: Record<string, string | undefined>): Promise<T> {
  if (!base || !key) fail('Set PLAUSIBLE_URL and PLAUSIBLE_API_KEY.')
  const q = new URLSearchParams(Object.entries(query).filter(([, v]) => v !== undefined) as [string, string][])
  const res = await fetch(`${base}/api/v1/admin${path}?${q}`, {
    headers: { authorization: `Bearer ${key}`, accept: 'application/json' },
  })
  const text = await res.text()
  if (!res.ok) fail(`${res.status} ${path}: ${text.slice(0, 300)}`)
  return JSON.parse(text) as T
}

const sessions = (site: string, flags: Flags) =>
  api<{ sessions: Session[] }>('/replays', {
    site_id: site,
    days: flags.days,
    limit: flags.limit,
    visitor: flags.visitor,
  }).then((r) => r.sessions)

const recording = (site: string, session: string) =>
  api<{ session_id: string; visitor_id: string; loads: RrwebEvent[][] }>(
    `/replays/${encodeURIComponent(session)}`,
    { site_id: site },
  )

type Flags = Record<string, string | undefined> & { json?: string }

function parse(argv: string[]) {
  const args: string[] = []
  const flags: Flags = {}
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!
    if (a === '--json') flags.json = '1'
    else if (a.startsWith('--')) flags[a.slice(2)] = argv[++i]
    else args.push(a)
  }
  return { args, flags }
}

const secs = (ms: number) => Math.round(ms / 1000)

/** The width the first page load reported, to tell phones from desktops. */
function width(loads: RrwebEvent[][]) {
  for (const load of loads) for (const e of load) if (e.type === 4 && e.data?.width) return e.data.width as number
  return undefined
}

interface Summary {
  session: string
  visitor: string
  started: string
  seconds: number
  device: 'mobile' | 'desktop' | '?'
  pages: string[]
  events: string[]
  counts: Extracted['counts']
  /** The last thing done before the recording ends. */
  last?: string
}

function summarize(s: Session, loads: RrwebEvent[][]): Summary | undefined {
  const x = extract(loads)
  if (!x) return undefined
  const w = width(loads)
  const acts = x.timeline.filter((i) => i.kind !== 'pause' && i.kind !== 'section')
  const lastAct = acts.at(-1)
  return {
    session: s.session_id,
    visitor: s.visitor_id,
    started: s.started_at,
    seconds: secs(x.endedAt - x.startedAt),
    device: w === undefined ? '?' : w < 768 ? 'mobile' : 'desktop',
    pages: x.timeline.flatMap((i) => (i.kind === 'page' ? [i.path || '/'] : [])),
    events: x.timeline.flatMap((i) => (i.kind === 'event' ? [i.name] : [])),
    counts: x.counts,
    ...(lastAct && { last: renderTimeline([{ ...lastAct, t: 0 }]).slice(7) }),
  }
}

function tally(map: Map<string, number>, k: string) {
  map.set(k, (map.get(k) ?? 0) + 1)
}

function top(map: Map<string, number>, n = 10) {
  return [...map].sort((a, b) => b[1] - a[1]).slice(0, n)
}

async function scan(site: string, flags: Flags) {
  const list = await sessions(site, flags)
  const out: Summary[] = []
  const rage = new Map<string, number>()
  const dead = new Map<string, number>()
  const errors = new Map<string, number>()
  const exits = new Map<string, number>()
  const abandoned = new Map<string, number>()
  for (const s of list) {
    const { loads } = await recording(site, s.session_id)
    const x = extract(loads)
    const sum = summarize(s, loads)
    if (!x || !sum) continue
    if (flags.has && !sum.events.includes(flags.has)) continue
    out.push(sum)
    for (const i of x.timeline as Interaction[]) {
      if (i.kind === 'rage_click') tally(rage, targetText(i.target))
      if (i.kind === 'click' && i.dead) tally(dead, targetText(i.target))
      if (i.kind === 'error') tally(errors, i.message.slice(0, 120))
      if (i.kind === 'form_abandoned') tally(abandoned, `${i.form}: ${i.fields.join(', ')}`)
    }
    if (sum.last) tally(exits, `${sum.pages.at(-1) ?? '?'} · ${sum.last}`)
  }
  if (flags.json) {
    console.log(
      JSON.stringify(
        { sessions: out, rage: top(rage), dead: top(dead), errors: top(errors), abandoned: top(abandoned), exits: top(exits) },
        null,
        2,
      ),
    )
    return
  }
  for (const s of out) {
    const c = s.counts
    const flagsText = [
      c.rage_clicks && `rage ${c.rage_clicks}`,
      c.dead_clicks && `dead ${c.dead_clicks}`,
      c.errors && `errors ${c.errors}`,
      c.abandoned_forms && `abandoned ${c.abandoned_forms}`,
    ].filter(Boolean)
    console.log(
      `${s.started.slice(0, 16)}  ${s.session}  ${s.device.padEnd(7)} ${String(s.seconds).padStart(5)}s  ` +
        `${s.pages.join(' > ')}${s.events.length ? `  {${s.events.join(', ')}}` : ''}` +
        `${flagsText.length ? `  [${flagsText.join(', ')}]` : ''}`,
    )
  }
  const section = (title: string, rows: [string, number][]) => {
    if (!rows.length) return
    console.log(`\n${title}`)
    for (const [k, n] of rows) console.log(`  ${String(n).padStart(4)}  ${k}`)
  }
  console.log(`\n${out.length} sessions`)
  section('Rage clicks', top(rage))
  section('Dead clicks', top(dead))
  section('Errors', top(errors))
  section('Forms left unsent', top(abandoned))
  section('Last action before the recording ends', top(exits))
}

async function play(site: string, session: string) {
  const { loads, visitor_id } = await recording(site, session)
  const require = createRequire(import.meta.url)
  const dist = require.resolve('rrweb-player/dist/rrweb-player.umd.min.cjs')
  const js = readFileSync(dist, 'utf8')
  const css = readFileSync(join(dist, '..', 'style.min.css'), 'utf8')
  // Page loads play one after another, gaps between them closed up by skipInactive.
  const events = loads.flat()
  const x = extract(loads)
  const timeline = x ? renderTimeline(x.timeline) : ''
  const json = (v: unknown) => JSON.stringify(v).replace(/</g, '\\u003c')
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>${session}</title>
<style>${css}
body{font:13px system-ui;margin:16px;display:flex;gap:16px;background:#f4f4f5}
pre{white-space:pre-wrap;max-width:420px;max-height:90vh;overflow:auto;margin:0}</style></head>
<body><div id="p"></div><div><b>${site} · visitor ${visitor_id}</b><pre id="t"></pre></div>
<script>${js}</script>
<script>
const events = ${json(events)};
document.getElementById('t').textContent = ${json(timeline)};
new rrwebPlayer({ target: document.getElementById('p'), props: { events, width: 960, height: 600, skipInactive: true, showDebug: false, UNSAFE_replayCanvas: false } });
</script></body></html>`
  const file = join(tmpdir(), `replay-${session}.html`)
  writeFileSync(file, html)
  console.log(file)
  if (process.platform === 'darwin') execFile('open', [file])
}

async function main() {
  const { args, flags } = parse(process.argv.slice(2))
  const [cmd, site, session] = args
  if (!cmd || !site) fail('usage: replays list|scan|timeline|play <site> [session] [--days N] [--limit N] [--visitor ID] [--has EVENT] [--json]')
  switch (cmd) {
    case 'list': {
      const list = await sessions(site, flags)
      if (flags.json) return console.log(JSON.stringify(list, null, 2))
      for (const s of list)
        console.log(
          `${s.started_at.slice(0, 16)}  ${s.session_id}  visitor ${s.visitor_id}  ` +
            `${secs(Date.parse(s.ended_at) - Date.parse(s.started_at))}s  ${s.loads} loads  ${Math.round(s.bytes / 1024)} KB`,
        )
      return console.log(`${list.length} sessions`)
    }
    case 'timeline': {
      if (!session) fail('usage: replays timeline <site> <session>')
      const { loads } = await recording(site, session)
      const x = extract(loads)
      if (!x) fail('No events in this recording.')
      if (flags.json) return console.log(JSON.stringify(x, null, 2))
      console.log(`width ${width(loads) ?? '?'}px · ${secs(x.endedAt - x.startedAt)}s`)
      return console.log(renderTimeline(x.timeline))
    }
    case 'scan':
      return scan(site, flags)
    case 'play':
      if (!session) fail('usage: replays play <site> <session>')
      return play(site, session)
    default:
      fail(`Unknown command ${cmd}`)
  }
}

await main()
