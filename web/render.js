/*
 * MD Viewer markdown renderer.
 *
 * Turns markdown text into a sanitized DocumentFragment plus an outline of its
 * headings. It runs inside the app's preview web view (see page.js) and in the
 * Node tests, which pass in a jsdom-backed DOMPurify.
 *
 * Pipeline: front matter -> markdown-it (GFM tables, task lists, footnotes,
 * alerts, heading ids, highlighting) -> DOMPurify -> local link rewriting.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory
  else root.createMarkdownRenderer = factory
})(typeof self !== 'undefined' ? self : this, function createMarkdownRenderer (deps) {
  'use strict'

  const { markdownit, footnote, hljs, DOMPurify } = deps

  // Scheme the app serves local images and files under (see LocalFileURL.swift).
  const LOCAL_FILE_PREFIX = 'mdv-file://local'

  const ALERT_TITLES = { note: 'Note', tip: 'Tip', important: 'Important', warning: 'Warning', caution: 'Caution' }

  // Top-level blocks get dir="auto", so a Hebrew or Arabic paragraph, list, quote
  // or table reads right to left. Their contents inherit it: marking list items
  // or quoted paragraphs separately would leave the list or quote itself
  // left-to-right, with bullets and borders on the wrong side.
  const UNDIRECTED_BLOCKS = new Set(['PRE', 'HR'])

  const SANITIZE_OPTIONS = {
    // Forms and embedded styles are never needed to read a document.
    FORBID_TAGS: ['style', 'form', 'button', 'textarea', 'select', 'option', 'optgroup', 'datalist', 'dialog'],
    FORBID_ATTR: ['autofocus'],
    RETURN_DOM_FRAGMENT: true
  }

  function highlight (code, info) {
    const language = (info || '').trim().split(/\s+/)[0].toLowerCase()
    if (language && hljs.getLanguage(language)) {
      try {
        return hljs.highlight(code, { language, ignoreIllegals: true }).value
      } catch (_) { /* fall through to plain text */ }
    }
    return '' // markdown-it escapes the code itself
  }

  const md = markdownit({ html: true, linkify: true, typographer: false, highlight })
    .use(footnote)
    .use(taskLists)
    .use(alerts)
    .use(headingIds)

  // --- markdown-it plugins -------------------------------------------------

  // GitHub task lists: "- [ ] todo" and "- [x] done" become disabled checkboxes.
  function taskLists (md) {
    md.core.ruler.after('inline', 'mdv_task_lists', state => {
      const tokens = state.tokens
      for (let i = 2; i < tokens.length; i++) {
        const inline = tokens[i]
        if (inline.type !== 'inline' || tokens[i - 1].type !== 'paragraph_open' || tokens[i - 2].type !== 'list_item_open') continue
        const first = inline.children[0]
        const match = first && first.type === 'text' && /^\[([ xX])\](?=\s|$)/.exec(first.content)
        if (!match) continue

        first.content = first.content.slice(match[0].length).replace(/^\s/, '')
        const checkbox = new state.Token('html_inline', '', 0)
        checkbox.content = `<input type="checkbox" class="task-list-item-checkbox" disabled${match[1] === ' ' ? '' : ' checked'}> `
        inline.children.unshift(checkbox)

        const item = tokens[i - 2]
        item.attrJoin('class', 'task-list-item')
        for (let j = i - 3; j >= 0; j--) {
          const t = tokens[j]
          if ((t.type === 'bullet_list_open' || t.type === 'ordered_list_open') && t.level === item.level - 1) {
            t.attrJoin('class', 'contains-task-list')
            break
          }
        }
      }
    })
  }

  // GitHub alerts: a blockquote whose first line is "[!NOTE]", "[!WARNING]", ...
  function alerts (md) {
    md.core.ruler.after('inline', 'mdv_alerts', state => {
      const tokens = state.tokens
      for (let i = 0; i < tokens.length - 2; i++) {
        if (tokens[i].type !== 'blockquote_open' || tokens[i + 1].type !== 'paragraph_open') continue
        const inline = tokens[i + 2]
        const first = inline.children && inline.children[0]
        const match = first && first.type === 'text' && /^\[!(note|tip|important|warning|caution)\]\s*$/i.exec(first.content)
        const next = inline.children[1]
        if (!match || (next && next.type !== 'softbreak')) continue

        const kind = match[1].toLowerCase()
        tokens[i].attrJoin('class', `markdown-alert markdown-alert-${kind}`)
        inline.children.splice(0, next ? 2 : 1)
        if (inline.children.length === 0) {
          tokens[i + 1].hidden = true
          tokens[i + 3].hidden = true
        }
        const title = new state.Token('html_block', '', 0)
        title.content = `<p class="markdown-alert-title">${ALERT_TITLES[kind]}</p>\n`
        tokens.splice(i + 1, 0, title)
      }
    })
  }

  // GitHub-style heading ids ("Hello, World!" -> "hello-world") and the outline.
  function headingIds (md) {
    md.core.ruler.push('mdv_heading_ids', state => {
      const seen = new Map()
      const outline = []
      const tokens = state.tokens
      for (let i = 0; i < tokens.length; i++) {
        if (tokens[i].type !== 'heading_open') continue
        const text = plainText(tokens[i + 1])
        const id = uniqueSlug(slugify(text) || 'section', seen)
        tokens[i].attrSet('id', id)
        outline.push({ level: Number(tokens[i].tag.slice(1)), text, id })
      }
      state.env.outline = outline
    })
  }

  function plainText (inline) {
    return (inline.children || [])
      .map(t => (t.type === 'text' || t.type === 'code_inline') ? t.content : (t.type === 'softbreak' ? ' ' : ''))
      .join('')
      .trim()
  }

  function slugify (text) {
    return text.toLowerCase().replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, '').replace(/ /g, '-')
  }

  function uniqueSlug (base, seen) {
    let slug = base
    if (seen.has(base)) {
      let count = seen.get(base)
      do { count++; slug = `${base}-${count}` } while (seen.has(slug))
      seen.set(base, count)
    }
    seen.set(slug, 0)
    return slug
  }

  // --- front matter ----------------------------------------------------------

  const FRONT_MATTER = /^---[ \t]*\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/

  function splitFrontMatter (source) {
    const match = FRONT_MATTER.exec(source)
    if (!match) return { frontMatter: null, body: source }
    return { frontMatter: match[1], body: source.slice(match[0].length) }
  }

  function renderFrontMatter (yaml) {
    const code = highlight(yaml, 'yaml') || md.utils.escapeHtml(yaml)
    return `<pre class="front-matter"><code class="language-yaml">${code}</code></pre>\n`
  }

  // --- links and images ---------------------------------------------------

  /**
   * Resolves a relative link or image path against the document's folder and
   * returns the app URL for it, or null when the link should stay as written
   * (web links, in-page anchors, other schemes).
   * baseDir and rootDir are file URLs of folders and end with "/".
   */
  function resolveLocal (href, { baseDir, rootDir } = {}, keepHash = false) {
    if (!href || !baseDir) return null
    const value = href.trim()
    if (value === '' || value.startsWith('#') || value.startsWith('//')) return null
    if (/^[a-z][a-z0-9+.-]*:/i.test(value)) return null

    let url
    try {
      url = (value.startsWith('/') && rootDir)
        ? new URL(value.replace(/^\/+/, ''), rootDir) // repository-root links, as on GitHub
        : new URL(value, baseDir)
    } catch (_) {
      return null
    }
    if (url.protocol !== 'file:') return null
    return LOCAL_FILE_PREFIX + url.pathname + (keepHash ? url.hash : '')
  }

  function postProcess (fragment, context) {
    for (const input of fragment.querySelectorAll('input')) {
      if ((input.getAttribute('type') || '').toLowerCase() === 'checkbox') input.setAttribute('disabled', '')
      else input.remove()
    }
    for (const el of fragment.querySelectorAll('[src], [poster]')) {
      for (const attr of ['src', 'poster']) {
        const resolved = resolveLocal(el.getAttribute(attr), context)
        if (resolved) el.setAttribute(attr, resolved)
      }
    }
    for (const el of fragment.querySelectorAll('[srcset]')) {
      // Relative srcset candidates would resolve against the app itself; drop them.
      if (!/^\s*(https?:|data:)/i.test(el.getAttribute('srcset'))) el.removeAttribute('srcset')
    }
    for (const link of fragment.querySelectorAll('a[href]')) {
      const href = link.getAttribute('href')
      if (href.trim().startsWith('//')) link.setAttribute('href', 'https:' + href.trim())
      const resolved = resolveLocal(href, context, true)
      if (resolved) link.setAttribute('href', resolved)
    }
    for (const img of fragment.querySelectorAll('img')) img.setAttribute('loading', 'lazy')
    for (const el of fragment.children) {
      if (!UNDIRECTED_BLOCKS.has(el.tagName) && !el.hasAttribute('dir')) el.setAttribute('dir', 'auto')
    }
  }

  // --- public API -------------------------------------------------------------

  /**
   * Renders markdown into a sanitized DocumentFragment.
   * options.baseDir: file URL of the document's folder (for relative links and images)
   * options.rootDir: file URL of the opened folder (for links starting with "/")
   */
  function render (source, options = {}) {
    const { frontMatter, body } = splitFrontMatter(String(source == null ? '' : source))
    const env = {}
    let html = md.render(body, env)
    if (frontMatter !== null) html = renderFrontMatter(frontMatter) + html

    const fragment = DOMPurify.sanitize(html, SANITIZE_OPTIONS)
    postProcess(fragment, options)
    return { fragment, outline: env.outline || [] }
  }

  return { render, resolveLocal, slugify }
})
