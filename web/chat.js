/*
 * MD Viewer chat transcript.
 *
 * Shows the items the app sends: the user's messages, Claude's replies, one
 * line per tool step, and notices. The app calls window.chat.* through
 * WKWebView.callAsyncJavaScript (see chat-page.js). The page has no way to
 * call back, so nothing in a reply can approve a tool or reach the app.
 * Replies go through the same markdown pipeline as documents, minus remote
 * images, whose URLs could carry data out.
 *
 * Runs in the app's chat web view and in the Node tests, which pass a jsdom
 * document and renderer.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory
  else root.createChatView = factory
})(typeof self !== 'undefined' ? self : this, function createChatView (deps) {
  'use strict'

  const { document, renderer, container, empty, status } = deps
  const elements = new Map()

  // Shown after a step that didn't simply finish.
  const STATE_LABELS = { failed: 'failed', denied: 'not allowed', stopped: 'stopped' }

  /**
   * Adds new items at the end and replaces changed ones in place.
   * options.baseDir: file URL of the chat's folder, for relative links in replies.
   */
  function upsert (items, options = {}) {
    const scroller = document.scrollingElement
    const wasAtBottom = !scroller || scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 48
    let sent = false
    for (const item of items) {
      const element = render(item, options)
      const existing = elements.get(item.id)
      if (existing) {
        existing.replaceWith(element)
      } else {
        container.appendChild(element)
        if (item.kind === 'user') sent = true
      }
      elements.set(item.id, element)
    }
    empty.hidden = elements.size > 0
    // Follow the conversation, unless the user scrolled up to read.
    if (scroller && (wasAtBottom || sent)) scroller.scrollTop = scroller.scrollHeight
  }

  function reset () {
    container.replaceChildren()
    elements.clear()
    empty.hidden = false
    setStatus(null)
  }

  /** A short line under the conversation ("Thinking…"), or nothing. */
  function setStatus (text) {
    status.textContent = text || ''
    status.hidden = !text
  }

  function render (item, options) {
    const element = document.createElement('div')
    element.className = `item ${item.kind}`
    element.dataset.id = item.id
    switch (item.kind) {
      case 'user':
        if (item.quote) element.appendChild(textElement('blockquote', 'quote', item.quote))
        element.appendChild(textElement('div', 'text', item.text))
        break
      case 'assistant': {
        const { fragment } = renderer.render(item.text || '', { baseDir: options.baseDir, rootDir: options.baseDir })
        blockRemoteImages(fragment)
        element.appendChild(fragment)
        element.classList.toggle('streaming', Boolean(item.streaming))
        break
      }
      case 'step': {
        element.classList.add(`state-${item.state || 'done'}`)
        element.dataset.icon = item.icon || 'other'
        if (item.detail) element.title = item.detail
        const marker = document.createElement('span')
        marker.className = 'marker'
        marker.setAttribute('aria-hidden', 'true')
        element.append(marker, textElement('span', 'label', item.text))
        if (item.code) element.appendChild(textElement('code', 'code', item.code))
        if (STATE_LABELS[item.state]) element.appendChild(textElement('span', 'state', STATE_LABELS[item.state]))
        break
      }
      default: // notice
        element.classList.add(`tone-${item.tone || 'info'}`)
        element.setAttribute('dir', 'auto')
        element.textContent = item.text
    }
    return element
  }

  /** Plain text that picks its own direction, so Hebrew reads right to left. */
  function textElement (tag, className, text) {
    const element = document.createElement(tag)
    element.className = className
    element.setAttribute('dir', 'auto')
    element.textContent = text || ''
    return element
  }

  function blockRemoteImages (fragment) {
    for (const image of fragment.querySelectorAll('img')) {
      if (/^\s*(https?:)?\/\//i.test(image.getAttribute('src') || '')) {
        const alt = image.getAttribute('alt')
        image.replaceWith(document.createTextNode(alt ? `[image: ${alt}]` : '[image]'))
      }
    }
    for (const element of fragment.querySelectorAll('[srcset]')) element.removeAttribute('srcset')
  }

  empty.hidden = false
  return { upsert, reset, setStatus }
})
