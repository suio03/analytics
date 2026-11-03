import type { Interaction } from './extract.ts'
import type { Target } from './mirror.ts'

/**
 * A timeline as plain lines, one per interaction: what a person or a model reads instead of
 * watching the recording.
 *
 *   00:12  click button "Choose Pro" [event Upgrade] in Pricing
 */

const clock = (ms: number) => {
  const s = Math.floor(ms / 1000)
  return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`
}

export function targetText(t: Target) {
  const parts = [t.tag === 'a' ? 'link' : t.type ? `${t.type} field` : t.tag]
  if (t.label) parts.push(JSON.stringify(t.label))
  if (t.href) parts.push(`→ ${t.href}`)
  if (t.event) parts.push(`[event ${t.event}]`)
  if (t.section) parts.push(`in ${t.section}`)
  if (t.near) parts.push(`under ${JSON.stringify(t.near)}`)
  if (t.form) parts.push(t.form === 'form' ? 'in a form' : `in form ${t.form}`)
  if (!t.interactive) parts.push('(not a control)')
  return parts.join(' ')
}

function line(i: Interaction) {
  switch (i.kind) {
    case 'page':
      return `page ${i.path || '/'}${i.seconds !== undefined ? ` (${i.seconds}s` : ''}${
        i.depth !== undefined ? `, scrolled ${Math.round(i.depth * 100)}%` : ''
      }${i.seconds !== undefined ? ')' : ''}`
    case 'click':
      return `click ${targetText(i.target)}${i.dead ? ' — nothing happened' : ''}`
    case 'rage_click':
      return `rage click ×${i.count} ${targetText(i.target)}${i.dead ? ' — nothing happened' : ''}`
    case 'input':
      return `edit ${targetText(i.target)}${i.checked !== undefined ? (i.checked ? ' (checked)' : ' (unchecked)') : ''}`
    case 'form_abandoned':
      return `left ${i.form === 'page' ? 'fields' : i.form === 'form' ? 'a form' : `form ${i.form}`} unsent after filling ${i.fields.map((f) => JSON.stringify(f)).join(', ')}`
    case 'section':
      return `reached ${JSON.stringify(i.name)}`
    case 'pause':
      return `paused ${i.seconds}s${i.over ? ` over ${JSON.stringify(i.over)}` : ''}`
    case 'event':
      return `event ${i.name}${
        i.props
          ? ` ${Object.entries(i.props)
              .map(([k, v]) => `${k}=${v}`)
              .join(' ')}`
          : ''
      }`
    case 'error':
      return `error ${JSON.stringify(i.message)}${i.source ? ` (${i.source})` : ''}`
  }
}

export function renderTimeline(timeline: Interaction[]) {
  return timeline.map((i) => `${clock(i.t)}  ${line(i)}`).join('\n')
}
