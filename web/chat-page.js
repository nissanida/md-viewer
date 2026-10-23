/*
 * Glue between the app and the chat page: builds the transcript view and
 * exposes it as window.chat. The app calls it; nothing here calls the app.
 */
(function () {
  'use strict'

  const renderer = createMarkdownRenderer({
    markdownit: window.markdownit,
    footnote: window.markdownitFootnote,
    hljs: window.hljs,
    DOMPurify: window.DOMPurify
  })

  window.chat = createChatView({
    document,
    renderer,
    container: document.getElementById('chat'),
    empty: document.getElementById('empty'),
    status: document.getElementById('status')
  })
})()
