import { describe, expect, it } from 'vitest'
import { extract, type RrwebEvent } from './extract.ts'
import type { SerializedNode } from './mirror.ts'
import { renderTimeline } from './render.ts'

/** A small page: a pricing card with a button and a masked note, a form, and a footer. */
const el = (
  id: number,
  tagName: string,
  childNodes: SerializedNode[] = [],
  attributes: Record<string, unknown> = {},
): SerializedNode => ({ type: 2, id, tagName, attributes, childNodes })
const text = (id: number, textContent: string): SerializedNode => ({ type: 3, id, textContent })

const page = {
  type: 0,
  id: 1,
  childNodes: [
    el(2, 'html', [
      el(3, 'body', [
        el(4, 'h2', [text(5, 'Pro')]),
        el(6, 'p', [text(7, '***** **** *** *****')]),
        el(8, 'button', [el(9, 'span', [text(10, 'Choose Pro')])], { 'data-rc-event': 'Upgrade' }),
        el(11, 'div', [text(12, '*******')]),
        el(
          20,
          'form',
          [
            el(21, 'label', [
              text(22, 'Email'),
              el(23, 'input', [], { type: 'email', name: 'email' }),
            ]),
            el(24, 'input', [], { type: 'checkbox', id: 'terms' }),
            el(25, 'label', [text(26, 'Accept terms')], { for: 'terms' }),
            el(27, 'button', [text(28, 'Send')]),
          ],
          { id: 'signup' },
        ),
        el(30, 'a', [text(31, 'Docs')], { href: 'https://shop.test/docs?ref=x' }),
      ]),
    ]),
  ],
} satisfies SerializedNode

const T0 = 1_000_000

/** Events at offsets from T0, starting with the page load. */
function load(start: number, ...rest: [number, Omit<RrwebEvent, 'timestamp'>][]): RrwebEvent[] {
  return [
    {
      type: 4,
      timestamp: T0 + start,
      data: { href: 'https://shop.test/pricing?email=a@b.test', width: 1200, height: 800 },
    },
    { type: 2, timestamp: T0 + start, data: { node: page, initialOffset: { top: 0, left: 0 } } },
    ...rest.map(([at, e]) => ({ ...e, timestamp: T0 + start + at })),
  ]
}

const click = (id: number, x = 10, y = 10) => ({ type: 3, data: { source: 2, type: 2, id, x, y } })
const input = (id: number, extra = {}) => ({
  type: 3,
  data: { source: 5, id, text: '*****', ...extra },
})
const mutation = { type: 3, data: { source: 0, adds: [], removes: [], texts: [], attributes: [] } }
const scroll = (y: number) => ({ type: 3, data: { source: 3, id: 1, x: 0, y } })
const custom = (tag: string, payload: unknown) => ({ type: 5, data: { tag, payload } })
const idle = (at: number): [number, Omit<RrwebEvent, 'timestamp'>] => [
  at,
  { type: 3, data: { source: 1, positions: [{ x: 1, y: 1, id: 11, timeOffset: 0 }] } },
]

describe('extract', () => {
  it('names click targets by the control they belong to, never by masked text', () => {
    const r = extract([load(0, [1000, click(10)], [1100, mutation], [3000, click(12)], idle(5000))])
    const [, first, second] = r?.timeline ?? []
    expect(first).toMatchObject({
      kind: 'click',
      target: {
        tag: 'button',
        label: 'Choose Pro',
        event: 'Upgrade',
        near: 'Pro',
        interactive: true,
      },
    })
    expect(first).not.toHaveProperty('dead')
    expect(second).toMatchObject({
      kind: 'click',
      dead: true,
      target: { tag: 'div', interactive: false },
    })
    expect(second?.kind === 'click' && second.target.label).toBeUndefined()
  })

  it('folds rapid clicks on one element into a rage click', () => {
    const r = extract([
      load(0, [1000, click(8)], [1200, click(8)], [1400, click(8)], [1500, click(8)], idle(4000)),
    ])
    expect(r?.timeline.filter((i) => i.kind !== 'page')).toEqual([
      expect.objectContaining({ kind: 'rage_click', count: 4, dead: true }),
    ])
    expect(r?.counts).toMatchObject({ clicks: 1, rage_clicks: 1, dead_clicks: 1 })
  })

  it('does not call a click dead when the page left right after it', () => {
    const r = extract([load(0, [1000, click(30)]), load(1500)])
    const c = r?.timeline.find((i) => i.kind === 'click')
    expect(c).not.toHaveProperty('dead')
    expect(c).toMatchObject({ target: { tag: 'a', href: '/docs' } })
  })

  it('ignores values the page set itself', () => {
    const r = extract([load(0, [1000, input(23, { userTriggered: false })], idle(9000))])
    expect(r?.timeline.map((i) => i.kind)).toEqual(['page'])
    expect(r?.counts).toMatchObject({ abandoned_forms: 0 })
  })

  it('reports forms edited and left unsent, with field labels only', () => {
    const r = extract([
      load(
        0,
        [1000, input(23)],
        [1200, input(23)],
        [2000, input(24, { isChecked: true })],
        idle(9000),
      ),
    ])
    const kinds = r?.timeline.map((i) => i.kind)
    expect(kinds).toEqual(['page', 'input', 'input', 'form_abandoned'])
    expect(r?.timeline[2]).toMatchObject({
      target: { label: 'Accept terms', type: 'checkbox' },
      checked: true,
    })
    expect(r?.timeline[3]).toEqual({
      t: 1000 + 1000,
      kind: 'form_abandoned',
      form: 'signup',
      fields: ['Email', 'Accept terms'],
    })
    expect(JSON.stringify(r)).not.toContain('a@b.test')
  })

  it('does not report a form that was sent', () => {
    const r = extract([load(0, [1000, input(23)], [2000, click(28)], [2100, mutation], idle(9000))])
    expect(r?.counts.abandoned_forms).toBe(0)
  })

  it('notes sections reached by scrolling, pauses, errors and route changes', () => {
    const layout = custom('layout', {
      height: 3000,
      viewport: 800,
      sections: [
        { name: 'Pricing', top: 0 },
        { name: 'FAQ', top: 1500 },
        { name: 'Footer', top: 2800 },
      ],
    })
    const r = extract([
      load(
        0,
        [100, layout],
        [1000, scroll(1000)],
        idle(2000),
        [15_000, click(8)],
        [15_200, custom('error', { message: 'boom', source: '/app.js' })],
        [16_000, custom('nav', { href: 'https://shop.test/checkout?token=s' })],
        idle(20_000),
      ),
    ])
    expect(renderTimeline(r?.timeline ?? [])).toBe(
      [
        '00:00  page /pricing (16s, scrolled 60%)',
        '00:01  reached "FAQ"',
        '00:01  paused 14s over "Pro"',
        '00:15  click button "Choose Pro" [event Upgrade] under "Pro"',
        '00:15  error "boom" (/app.js)',
        '00:16  page /checkout (4s)',
      ].join('\n'),
    )
  })
  it('lists analytics events the site mirrored into the recording', () => {
    const r = extract([
      load(0, [500, custom('event', { name: 'checkout_click', props: { sku: 'pack_240' } })], idle(2000)),
    ])
    expect(renderTimeline(r?.timeline ?? [])).toContain('00:00  event checkout_click sku=pack_240')
    expect(r?.counts.events).toBe(1)
  })
})
