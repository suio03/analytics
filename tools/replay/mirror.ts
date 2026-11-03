/**
 * Just enough of the recorded page's DOM to say what an rrweb node id was: its tag, the text
 * the recorder kept, and the section and form around it. Built from full snapshots and kept
 * current with mutations.
 */

const NodeType = { Document: 0, Element: 2, Text: 3 } as const

export interface SerializedNode {
  type: number
  id: number
  tagName?: string
  attributes?: Record<string, unknown>
  childNodes?: SerializedNode[]
  textContent?: string
}

export interface Mutation {
  adds?: { parentId: number; node: SerializedNode }[]
  removes?: { parentId: number; id: number }[]
  texts?: { id: number; value: string | null }[]
  attributes?: { id: number; attributes: Record<string, unknown> }[]
}

interface MirrorNode {
  id: number
  type: number
  tag: string
  attrs: Record<string, string>
  text: string
  parent?: number
  children: number[]
}

/** What a click or input landed on, in words a reader of the timeline can follow. */
export interface Target {
  tag: string
  /** Visible text, accessible name, or field name: never a typed value. */
  label?: string
  href?: string
  /** `data-rc-event`, when the element sends a custom event. */
  event?: string
  section?: string
  /** The heading the element sits under, when no named section says where it is. */
  near?: string
  form?: string
  /** Whether the element is built to be clicked; dead clicks on anything else are weaker signals. */
  interactive: boolean
  /** An input's type (`email`, `checkbox`…), which says what kind of field it is. */
  type?: string
  /** A submit button, or a link that opens a new tab (so the page itself does not react). */
  submits?: true
  newTab?: true
}

const LABEL_LIMIT = 80
const INTERACTIVE_TAGS = new Set(['a', 'button', 'input', 'select', 'textarea', 'label', 'summary'])
const INTERACTIVE_ROLES = new Set(['button', 'link', 'tab', 'menuitem', 'checkbox', 'switch'])
const FIELD_TAGS = new Set(['input', 'select', 'textarea'])

/** Text the recorder masked arrives as asterisks and says nothing. */
const readable = (text: string) => {
  const t = text.replace(/\s+/g, ' ').trim()
  return /^[*\s]*$/.test(t) ? '' : t.slice(0, LABEL_LIMIT)
}

const attrText = (v: unknown) => (typeof v === 'string' ? v : v === true ? '' : undefined)

export class Mirror {
  private nodes = new Map<number, MirrorNode>()
  documentId?: number

  reset(root: SerializedNode) {
    this.nodes.clear()
    this.documentId = root.id
    this.add(root)
  }

  private add(node: SerializedNode, parent?: number) {
    const attrs: Record<string, string> = {}
    for (const [k, v] of Object.entries(node.attributes ?? {})) {
      const text = attrText(v)
      if (text !== undefined) attrs[k] = text
    }
    this.nodes.set(node.id, {
      id: node.id,
      type: node.type,
      tag: (node.tagName ?? '').toLowerCase(),
      attrs,
      text: node.type === NodeType.Text ? (node.textContent ?? '') : '',
      parent,
      children: [],
    })
    if (parent !== undefined) this.nodes.get(parent)?.children.push(node.id)
    for (const child of node.childNodes ?? []) this.add(child, node.id)
  }

  apply(m: Mutation) {
    for (const r of m.removes ?? []) {
      const parent = this.nodes.get(r.parentId)
      if (parent) parent.children = parent.children.filter((c) => c !== r.id)
      this.drop(r.id)
    }
    for (const a of m.adds ?? []) {
      if (this.nodes.has(a.parentId)) this.add(a.node, a.parentId)
    }
    for (const t of m.texts ?? []) {
      const node = this.nodes.get(t.id)
      if (node) node.text = t.value ?? ''
    }
    for (const a of m.attributes ?? []) {
      const node = this.nodes.get(a.id)
      if (!node) continue
      for (const [k, v] of Object.entries(a.attributes)) {
        const text = attrText(v)
        if (text === undefined) delete node.attrs[k]
        else node.attrs[k] = text
      }
    }
  }

  private drop(id: number) {
    const node = this.nodes.get(id)
    if (!node) return
    this.nodes.delete(id)
    for (const c of node.children) this.drop(c)
  }

  has(id: number) {
    return this.nodes.has(id)
  }

  private textOf(id: number, depth = 0): string {
    const node = this.nodes.get(id)
    if (!node || depth > 8) return ''
    if (node.type === NodeType.Text) return node.text
    if (node.tag === 'script' || node.tag === 'style') return ''
    return node.children.map((c) => this.textOf(c, depth + 1)).join(' ')
  }

  private *ancestors(id: number) {
    let node = this.nodes.get(id)
    while (node) {
      yield node
      node = node.parent === undefined ? undefined : this.nodes.get(node.parent)
    }
  }

  /** The element itself, or the nearest element above a text node. */
  private element(id: number) {
    for (const node of this.ancestors(id)) if (node.type === NodeType.Element) return node
    return undefined
  }

  /**
   * The thing a visitor meant to click: the nearest interactive ancestor, since clicks often land
   * on an icon or span inside a button.
   */
  private clickable(id: number) {
    let depth = 0
    for (const node of this.ancestors(id)) {
      if (depth++ > 6) break
      if (isInteractive(node)) return node
    }
    return this.element(id)
  }

  describe(id: number): Target | undefined {
    const node = this.clickable(id)
    if (!node) return undefined
    const a = node.attrs
    const field = FIELD_TAGS.has(node.tag)
    const label =
      readable(a['aria-label'] ?? '') ||
      (field
        ? readable(this.fieldLabel(node) ?? '') ||
          readable(a.placeholder ?? '') ||
          readable(a.name ?? '') ||
          readable(a.type ?? '')
        : readable(this.textOf(node.id))) ||
      readable(a.title ?? '') ||
      readable(a.alt ?? '') ||
      readable(a.id ?? '')
    const target: Target = { tag: node.tag, interactive: isInteractive(node) }
    if (label) target.label = label
    if (node.tag === 'a' && a.href) target.href = linkOf(a.href)
    if (node.tag === 'input') target.type = a.type || 'text'
    if (a.target === '_blank') target.newTab = true
    if (
      (node.tag === 'button' && a.type !== 'button' && a.type !== 'reset') ||
      (node.tag === 'input' && (a.type === 'submit' || a.type === 'image'))
    )
      target.submits = true
    if (a['data-rc-event']) target.event = a['data-rc-event']
    for (const up of this.ancestors(node.id)) {
      if (!target.section && up.attrs['data-rc-section'])
        target.section = up.attrs['data-rc-section']
      if (!target.form && up.tag === 'form')
        target.form =
          up.attrs.id || up.attrs.name || (up.attrs.action && pathOf(up.attrs.action)) || 'form'
    }
    if (!target.section) {
      const near = this.heading(node.id)
      if (near && near !== target.label) target.near = near
    }
    return target
  }

  /**
   * The closest heading before the element: inside it, then among the earlier siblings of each
   * ancestor, walking up.
   */
  private heading(id: number) {
    let child = id
    let depth = 0
    for (const up of this.ancestors(id)) {
      if (depth++ > 8) break
      if (up.id === id) continue
      const before = up.children.slice(0, up.children.indexOf(child)).reverse()
      for (const c of before) {
        const found = this.lastHeading(c)
        if (found) return found
      }
      child = up.id
    }
    return undefined
  }

  private lastHeading(id: number, depth = 0): string | undefined {
    const node = this.nodes.get(id)
    if (!node || node.type !== NodeType.Element || depth > 4) return undefined
    if (/^h[1-6]$/.test(node.tag)) return readable(this.textOf(node.id)) || undefined
    for (const c of [...node.children].reverse()) {
      const found = this.lastHeading(c, depth + 1)
      if (found) return found
    }
    return undefined
  }

  /** The `<label for>` text of a field, or the label it sits in. */
  private fieldLabel(node: MirrorNode) {
    for (const up of this.ancestors(node.id)) if (up.tag === 'label') return this.textOf(up.id)
    if (!node.attrs.id) return undefined
    for (const other of this.nodes.values())
      if (other.tag === 'label' && other.attrs.for === node.attrs.id) return this.textOf(other.id)
    return undefined
  }
}

function isInteractive(node: MirrorNode) {
  return (
    INTERACTIVE_TAGS.has(node.tag) ||
    INTERACTIVE_ROLES.has(node.attrs.role ?? '') ||
    'data-rc-event' in node.attrs ||
    'onclick' in node.attrs
  )
}

/** A link's host (when it leaves the page's origin, as far as the recording shows) and path. */
function linkOf(href: string) {
  return /^https?:\/\//.test(href) ? `${new URL(href).host}${pathOf(href)}` : pathOf(href)
}

/** Paths only: query strings and fragments can carry tokens and emails. */
export function pathOf(href: string) {
  try {
    return new URL(href, 'http://x').pathname
  } catch {
    return ''
  }
}
