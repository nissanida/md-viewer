// Tests for web/render.js, run with `make test-web`.
// They load the same vendored libraries the app ships, plus jsdom for DOMPurify.
const test = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
const { JSDOM } = require('jsdom')

const web = path.join(__dirname, '..', '..', 'web')
const window = new JSDOM('<!doctype html><body></body>').window
const createMarkdownRenderer = require(path.join(web, 'render.js'))
const renderer = createMarkdownRenderer({
  markdownit: require(path.join(web, 'vendor/markdown-it.min.js')),
  footnote: require(path.join(web, 'vendor/markdown-it-footnote.min.js')),
  hljs: require(path.join(web, 'vendor/highlight.min.js')),
  DOMPurify: require(path.join(web, 'vendor/purify.min.js'))(window)
})

const docDir = 'file:///Users/me/Notes%20Folder/docs/'
const rootDir = 'file:///Users/me/Notes%20Folder/'

function render (markdown, options = { baseDir: docDir, rootDir }) {
  const { fragment, outline } = renderer.render(markdown, options)
  const container = window.document.createElement('div')
  container.appendChild(fragment)
  return { html: container.innerHTML, dom: container, outline }
}

test('renders GitHub tables', () => {
  const { dom } = render('| Name | Size |\n| --- | ---: |\n| a | 1 |')
  assert.equal(dom.querySelectorAll('table th').length, 2)
  assert.equal(dom.querySelector('table td').textContent, 'a')
})

test('renders task lists as disabled checkboxes', () => {
  const { dom } = render('- [ ] todo\n- [x] done\n- plain')
  const boxes = dom.querySelectorAll('input[type=checkbox]')
  assert.equal(boxes.length, 2)
  assert.ok(boxes[0].disabled && !boxes[0].checked)
  assert.ok(boxes[1].disabled && boxes[1].checked)
  assert.ok(dom.querySelector('ul').classList.contains('contains-task-list'))
  assert.equal(dom.querySelectorAll('li.task-list-item').length, 2)
  assert.equal(dom.querySelectorAll('li')[1].textContent.trim(), 'done')
})

test('highlights fenced code by language', () => {
  const { dom } = render('```js\nconst x = 1\n```')
  const code = dom.querySelector('pre code.language-js')
  assert.ok(code, 'code block keeps its language class')
  assert.ok(code.querySelector('.hljs-keyword'), 'keywords are highlighted')
})

test('leaves unknown languages as escaped plain text', () => {
  const { dom } = render('```nosuchlang\n<b>x</b>\n```')
  assert.equal(dom.querySelector('pre code').textContent, '<b>x</b>\n')
  assert.equal(dom.querySelector('pre b'), null)
})

test('renders footnotes', () => {
  const { dom } = render('Claim.[^1]\n\n[^1]: Source.')
  assert.ok(dom.querySelector('sup.footnote-ref a[href="#fn1"]'))
  assert.match(dom.querySelector('section.footnotes').textContent, /Source\./)
})

test('resolves relative images against the document folder', () => {
  const { dom } = render('![a](img/a.png) ![b](../shared/b.png) <img src="c d.png">')
  const sources = [...dom.querySelectorAll('img')].map(img => img.getAttribute('src'))
  assert.deepEqual(sources, [
    'mdv-file://local/Users/me/Notes%20Folder/docs/img/a.png',
    'mdv-file://local/Users/me/Notes%20Folder/shared/b.png',
    'mdv-file://local/Users/me/Notes%20Folder/docs/c%20d.png'
  ])
})

test('handles folders with Hebrew names', () => {
  const baseDir = 'file:///Users/me/%D7%9E%D7%A1%D7%9E%D7%9B%D7%99%D7%9D/'
  const { dom } = render('![](%D7%AA%D7%9E%D7%95%D7%A0%D7%94.png)', { baseDir })
  assert.equal(dom.querySelector('img').getAttribute('src'),
    'mdv-file://local/Users/me/%D7%9E%D7%A1%D7%9E%D7%9B%D7%99%D7%9D/%D7%AA%D7%9E%D7%95%D7%A0%D7%94.png')
})

test('rewrites links to local files but keeps web links and anchors', () => {
  const { dom } = render('[a](other.md#setup) [b](/README.md) [c](https://example.com) [d](#intro) [e](mailto:x@y.z)')
  const hrefs = [...dom.querySelectorAll('a')].map(a => a.getAttribute('href'))
  assert.deepEqual(hrefs, [
    'mdv-file://local/Users/me/Notes%20Folder/docs/other.md#setup',
    'mdv-file://local/Users/me/Notes%20Folder/README.md',
    'https://example.com',
    '#intro',
    'mailto:x@y.z'
  ])
})

test('removes scripts, event handlers and dangerous elements', () => {
  const { html, dom } = render([
    '<script>alert(1)</script>',
    '<img src="x.png" onerror="alert(2)">',
    '[click](javascript:alert(3))',
    '<a href="javascript:alert(4)">raw</a>',
    '<iframe src="https://evil.example"></iframe>',
    '<style>body { display: none }</style>',
    '<form action="https://evil.example"><input type="text" name="q"></form>',
    '<svg><script>alert(5)</script></svg>',
    '<object data="x.swf"></object><embed src="x.swf">'
  ].join('\n\n'))
  // markdown-it leaves "[click](javascript:...)" as plain text, which is harmless.
  assert.doesNotMatch(html, /<script|onerror|href="javascript:/i)
  assert.ok([...dom.querySelectorAll('a')].every(a => !/^javascript:/i.test(a.getAttribute('href') || '')))
  for (const tag of ['script', 'iframe', 'style', 'form', 'input', 'object', 'embed']) {
    assert.equal(dom.querySelector(tag), null, `${tag} is removed`)
  }
})

test('gives headings GitHub-style ids and returns the outline', () => {
  const { dom, outline } = render('# Hello, World!\n## Setup\n## Setup\n### שלום עולם')
  const ids = [...dom.querySelectorAll('h1, h2, h3')].map(h => h.id)
  assert.deepEqual(ids, ['hello-world', 'setup', 'setup-1', 'שלום-עולם'])
  assert.deepEqual(outline.map(h => [h.level, h.text]), [[1, 'Hello, World!'], [2, 'Setup'], [2, 'Setup'], [3, 'שלום עולם']])
})

test('shows front matter as a code block instead of a heading', () => {
  const { dom } = render('---\ntitle: Notes\ntags: [a, b]\n---\n# Body')
  assert.ok(dom.querySelector('pre.front-matter'))
  assert.equal(dom.querySelector('hr'), null)
  assert.equal(dom.querySelector('h1').textContent, 'Body')
})

test('renders GitHub alerts', () => {
  const { dom } = render('> [!WARNING]\n> Back up first.')
  const quote = dom.querySelector('blockquote.markdown-alert-warning')
  assert.ok(quote)
  assert.equal(quote.querySelector('.markdown-alert-title').textContent, 'Warning')
  assert.doesNotMatch(quote.textContent, /\[!WARNING\]/)
})

test('lets each block choose its own text direction', () => {
  const { dom } = render('שלום\n\nHello')
  assert.deepEqual([...dom.querySelectorAll('p')].map(p => p.getAttribute('dir')), ['auto', 'auto'])
})

test('gives a list one direction that its items inherit', () => {
  // A Hebrew list must be right-to-left as a whole, so its bullets sit on the right.
  const { dom } = render('- פריט ראשון\n- פריט שני\n\n> ציטוט\n>\n> עוד שורה')
  assert.equal(dom.querySelector('ul').getAttribute('dir'), 'auto')
  assert.equal(dom.querySelector('li').getAttribute('dir'), null)
  assert.equal(dom.querySelector('blockquote').getAttribute('dir'), 'auto')
  assert.equal(dom.querySelector('blockquote p').getAttribute('dir'), null)
})
