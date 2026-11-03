import { Mirror, type Mutation, pathOf, type SerializedNode, type Target } from './mirror.ts'

/**
 * Turns a session's rrweb events into the timeline a reader (or a model) can follow: pages,
 * clicks and what they landed on, fields edited, sections reached, pauses, errors, and the
 * frustration signals Clarity calls rage and dead clicks. Typed values never appear: the recorder
 * masks them, and fields are named by their labels.
 */

/** Bump when the rules change, so stored sessions are extracted again. */
export const EXTRACT_VERSION = 1

const EventType = { FullSnapshot: 2, Incremental: 3, Meta: 4, Custom: 5 } as const
const Source = { Mutation: 0, MouseMove: 1, MouseInteraction: 2, Scroll: 3, Resize: 4, Input: 5 }
const Mouse = { Click: 2, DblClick: 4 } as const

/** Clicks this close in time and space are one burst. */
const BURST_MS = 700
const BURST_PX = 40
const RAGE_CLICKS = 3
/** A click with no DOM change, scroll, input or navigation this soon after did nothing. */
const DEAD_MS = 1000
/** A gap this long between actions on a page is a pause worth noting. */
const PAUSE_MS = 10_000
/** A section counts as reached once its top is this far down the viewport. */
const SECTION_IN_VIEW = 0.8

export interface RrwebEvent {
  type: number
  timestamp: number
  // rrweb payloads vary by event type.
  data?: any
}

/** `t` is milliseconds since the session's first event. */
export type Interaction =
  | { t: number; kind: 'page'; path: string; seconds?: number; depth?: number }
  | { t: number; kind: 'click'; target: Target; dead?: true }
  | { t: number; kind: 'rage_click'; target: Target; count: number; dead?: true }
  | { t: number; kind: 'input'; target: Target; checked?: boolean }
  | { t: number; kind: 'form_abandoned'; form: string; fields: string[] }
  | { t: number; kind: 'section'; name: string }
  | { t: number; kind: 'pause'; seconds: number; over?: string }
  | { t: number; kind: 'error'; message: string; source?: string }
  /** An analytics event the site sent (`track(name, props)`), mirrored into the recording. */
  | { t: number; kind: 'event'; name: string; props?: Record<string, string | number | boolean> }

export interface Extracted {
  startedAt: number
  endedAt: number
  timeline: Interaction[]
  counts: {
    pages: number
    clicks: number
    rage_clicks: number
    dead_clicks: number
    errors: number
    abandoned_forms: number
    events: number
  }
}

type Click = Extract<Interaction, { kind: 'click' | 'rage_click' }>

interface Burst {
  click: Click
  id: number
  at: number
  x: number
  y: number
  last: number
  count: number
  /** When the page last reacted, to tell dead clicks. */
  reacted: boolean
}

interface FormState {
  fields: Set<string>
  lastInput: number
  submitted: boolean
}

/**
 * Extracts one session. `loads` are the session's page loads, each an ordered list of events
 * starting with the full snapshot; a load whose snapshot was lost is skipped.
 */
export function extract(loads: RrwebEvent[][]): Extracted | undefined {
  const ordered = loads
    .filter((l) => l.some((e) => e.type === EventType.FullSnapshot))
    .sort((a, b) => (a[0]?.timestamp ?? 0) - (b[0]?.timestamp ?? 0))
  const first = ordered[0]?.[0]
  if (!first) return undefined
  const start = first.timestamp
  const timeline: Interaction[] = []
  const at = (ts: number) => Math.max(0, Math.round(ts - start))
  let end = start

  for (const [index, events] of ordered.entries()) {
    const hasNext = index < ordered.length - 1
    const mirror = new Mirror()
    let host = ''
    let page: Extract<Interaction, { kind: 'page' }> | undefined
    let pageStart = 0
    let viewport = 0
    let layout: { height: number; sections: { name: string; top: number }[] } | undefined
    let scrollY = 0
    let maxDepth = 0
    let reached = new Set<string>()
    let lastAction = 0
    let hover: number | undefined
    let forms = new Map<string, FormState>()
    let burst: Burst | undefined
    /** Clicks waiting to see whether the page reacts. */
    let pending: Burst[] = []
    const loadEnd = events.at(-1)?.timestamp ?? start

    const describe = (id: number) => {
      const target = mirror.describe(id)
      if (target?.href && host && target.href.startsWith(`${host}/`))
        target.href = target.href.slice(host.length)
      return target
    }

    const reacted = (ts: number) => {
      pending = pending.filter((b) => {
        if (ts - b.at > DEAD_MS) return true
        b.reacted = true
        return false
      })
    }

    const closeBurst = () => {
      if (!burst) return
      if (burst.count >= RAGE_CLICKS) {
        const rage = burst.click as Interaction
        Object.assign(rage, { kind: 'rage_click', count: burst.count })
      }
      burst = undefined
    }

    const settle = (now: number) => {
      // Clicks old enough to judge, and every click once the page is gone.
      for (const b of pending) {
        const seenLongEnough = now - b.at > DEAD_MS
        if (!seenLongEnough) continue
        const t = b.click.target
        if (
          !b.reacted &&
          !t.newTab &&
          !(t.tag === 'input' || t.tag === 'select' || t.tag === 'textarea')
        )
          b.click.dead = true
      }
      pending = pending.filter((b) => now - b.at <= DEAD_MS)
    }

    const pause = (ts: number) => {
      if (lastAction && ts - lastAction >= PAUSE_MS) {
        const hovered = hover === undefined ? undefined : describe(hover)
        const over = hovered?.label ?? hovered?.near ?? hovered?.section
        timeline.push({
          t: at(lastAction),
          kind: 'pause',
          seconds: Math.round((ts - lastAction) / 1000),
          ...(over && { over }),
        })
      }
      lastAction = ts
    }

    const updateSections = (ts: number, silent: boolean) => {
      if (!layout || !viewport) return
      maxDepth = Math.max(maxDepth, Math.min(1, (scrollY + viewport) / layout.height))
      for (const s of layout.sections) {
        if (!s.name || reached.has(s.name) || s.top > scrollY + viewport * SECTION_IN_VIEW) continue
        reached.add(s.name)
        if (!silent) timeline.push({ t: at(ts), kind: 'section', name: s.name })
      }
    }

    const endPage = (ts: number) => {
      closeBurst()
      for (const [form, f] of forms)
        if (!f.submitted && f.fields.size)
          timeline.push({ t: at(f.lastInput), kind: 'form_abandoned', form, fields: [...f.fields] })
      if (page) {
        page.seconds = Math.round((ts - pageStart) / 1000)
        if (layout) page.depth = Math.round(maxDepth * 100) / 100
      }
      forms = new Map()
      reached = new Set()
      maxDepth = 0
      lastAction = 0
    }

    const startPage = (href: string, ts: number) => {
      page = { t: at(ts), kind: 'page', path: pathOf(href) }
      pageStart = ts
      lastAction = ts
      timeline.push(page)
    }

    for (const e of events) {
      const d = e.data ?? {}
      const ts = e.timestamp
      end = Math.max(end, ts)
      settle(ts)

      if (e.type === EventType.Meta) {
        try {
          host = new URL(d.href).host
        } catch {}
        viewport = d.height ?? viewport
        if (page) endPage(ts)
        startPage(d.href ?? '', ts)
      } else if (e.type === EventType.FullSnapshot) {
        mirror.reset(d.node as SerializedNode)
        scrollY = d.initialOffset?.top ?? 0
      } else if (e.type === EventType.Custom) {
        const payload = d.payload ?? {}
        if (d.tag === 'layout') {
          layout = { height: Math.max(1, payload.height ?? 1), sections: payload.sections ?? [] }
          viewport = payload.viewport ?? viewport
          // What is on screen when the page settles was not reached by scrolling.
          updateSections(ts, reached.size === 0 && scrollY === 0)
        } else if (d.tag === 'nav') {
          reacted(ts)
          endPage(ts)
          layout = undefined
          startPage(payload.href ?? '', ts)
        } else if (d.tag === 'event' && typeof payload.name === 'string') {
          timeline.push({
            t: at(ts),
            kind: 'event',
            name: payload.name,
            ...(payload.props && typeof payload.props === 'object' && { props: payload.props }),
          })
        } else if (d.tag === 'error') {
          timeline.push({
            t: at(ts),
            kind: 'error',
            message: String(payload.message ?? ''),
            ...(payload.source && { source: String(payload.source) }),
          })
        }
      } else if (e.type === EventType.Incremental) {
        if (d.source === Source.Mutation) {
          mirror.apply(d as Mutation)
          reacted(ts)
        } else if (d.source === Source.MouseMove) {
          const last = d.positions?.at(-1)
          if (last?.id !== undefined) hover = last.id
        } else if (d.source === Source.Scroll) {
          if (d.id === mirror.documentId) {
            scrollY = d.y ?? scrollY
            pause(ts)
            updateSections(ts, false)
          }
          reacted(ts)
        } else if (d.source === Source.Resize) {
          viewport = d.height ?? viewport
        } else if (d.source === Source.Input) {
          reacted(ts)
          const target = describe(d.id)
          if (!target) continue
          pause(ts)
          const previous = timeline.at(-1)
          const same = previous?.kind === 'input' && sameTarget(previous.target, target)
          if (!same)
            timeline.push({
              t: at(ts),
              kind: 'input',
              target,
              ...((target.type === 'checkbox' || target.type === 'radio') && {
                checked: Boolean(d.isChecked),
              }),
            })
          const key = target.form ?? 'page'
          const form = forms.get(key) ?? { fields: new Set(), lastInput: ts, submitted: false }
          form.fields.add(target.label ?? target.tag)
          form.lastInput = ts
          form.submitted = false
          forms.set(key, form)
        } else if (
          d.source === Source.MouseInteraction &&
          (d.type === Mouse.Click || d.type === Mouse.DblClick)
        ) {
          const target = describe(d.id)
          if (!target) continue
          if (target.submits || target.tag === 'button') {
            const form = forms.get(target.form ?? 'page')
            if (form) form.submitted = true
          }
          const x = d.x ?? 0
          const y = d.y ?? 0
          if (
            burst &&
            ts - burst.last <= BURST_MS &&
            (d.id === burst.id || Math.hypot(x - burst.x, y - burst.y) <= BURST_PX) &&
            sameTarget(target, burst.click.target)
          ) {
            burst.count++
            burst.last = ts
            continue
          }
          closeBurst()
          pause(ts)
          const click: Click = { t: at(ts), kind: 'click', target }
          timeline.push(click)
          burst = { click, id: d.id, at: ts, x, y, last: ts, count: 1, reacted: false }
          pending.push(burst)
        }
      }
    }

    // A click just before the page went away led somewhere when another load follows.
    if (hasNext) for (const b of pending) b.reacted = true
    settle(hasNext ? Number.POSITIVE_INFINITY : loadEnd)
    endPage(loadEnd)
  }

  // Abandoned forms are noted when their page ends, at the time of their last edit.
  timeline.sort((a, b) => a.t - b.t)
  const count = (kind: Interaction['kind']) => timeline.filter((i) => i.kind === kind).length
  return {
    startedAt: start,
    endedAt: end,
    timeline,
    counts: {
      pages: count('page'),
      clicks: count('click') + count('rage_click'),
      rage_clicks: count('rage_click'),
      dead_clicks: timeline.filter((i) => 'dead' in i && i.dead).length,
      errors: count('error'),
      abandoned_forms: count('form_abandoned'),
      events: count('event'),
    },
  }
}

/** Two descriptions of what is, as far as a reader can tell, the same element. */
const sameTarget = (a: Target, b: Target) =>
  a.tag === b.tag && a.label === b.label && a.form === b.form && a.section === b.section
