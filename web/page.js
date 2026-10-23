/*
 * Glue between the native app and the preview page.
 *
 * The app calls window.mdv.* through WKWebView.callAsyncJavaScript. The page has
 * no way to call back into the app: links are handled by the web view's
 * navigation policy on the native side, so document content cannot reach the
 * terminal or the file system.
 */
(function () {
  'use strict'

  const renderer = createMarkdownRenderer({
    markdownit: window.markdownit,
    footnote: window.markdownitFootnote,
    hljs: window.hljs,
    DOMPurify: window.DOMPurify
  })
  const doc = document.getElementById('doc')
  const status = document.getElementById('link-status')

  function scrollToAnchor (id) {
    if (!id) return false
    const target = document.getElementById(id) || document.getElementsByName(id)[0]
    if (!target) return false
    target.scrollIntoView({ block: 'start' })
    return true
  }

  // Shows where a link goes, like a browser's status bar.
  document.addEventListener('mouseover', event => {
    const link = event.target.closest && event.target.closest('a[href]')
    if (!link) return
    const href = link.getAttribute('href')
    status.textContent = href.startsWith('mdv-file://local') ? decodeURI(href.slice('mdv-file://local'.length)) : href
    status.hidden = href.startsWith('#')
  })
  document.addEventListener('mouseout', event => {
    if (event.target.closest && event.target.closest('a[href]')) status.hidden = true
  })

  window.mdv = {
    /**
     * Renders markdown and returns the outline of its headings.
     * options: { baseDir, rootDir, preserveScroll, fragment }
     */
    render (source, options) {
      options = options || {}
      const scrollY = window.scrollY
      const { fragment, outline } = renderer.render(source, options)
      doc.replaceChildren(fragment)
      doc.classList.toggle('is-empty', !String(source || '').trim())
      status.hidden = true

      if (options.preserveScroll) window.scrollTo(0, scrollY)
      else if (!scrollToAnchor(options.fragment)) window.scrollTo(0, 0)
      return outline
    },

    scrollToAnchor,

    selectionText () {
      return String(window.getSelection() || '')
    }
  }
})()
