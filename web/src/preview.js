import { marked, Lexer } from 'marked';
import DOMPurify from 'dompurify';
import { parseCSV, detectDelimiter, delimiterName } from './csv.js';
import { storage } from './storage.js';

const ZOOM_MIN = 0.5;
const ZOOM_MAX = 3;
const ZOOM_STEPS = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3];

const post = (msg) => window.webkit?.messageHandlers?.bridge?.postMessage(msg);

marked.setOptions({ gfm: true, breaks: false });

/**
 * Renders Markdown (sanitised, in-page) or HTML (sandboxed iframe with scripts disabled)
 * next to or instead of the editor.
 */
export class Preview {
  constructor(container) {
    this.container = container;
    this.markdownEl = container.querySelector('.markdown-body');
    this.frame = container.querySelector('iframe[sandbox]');
    this.tableEl = container.querySelector('.table-view');
    this.specFrame = container.querySelector('iframe.spec-viewer');
    this.specViewer = 'swagger';
    window.addEventListener('message', (e) => {
      if (e.source !== this.specFrame.contentWindow || e.data?.type !== 'viewerReady') return;
      this.specReady = true;
      this.postSpec();
    });
    this.language = null;
    this.timer = null;

    const copy = container.querySelector('.copy-rich');
    copy.addEventListener('click', () => {
      this.copyRich();
      copy.classList.add('done');
      copy.querySelector('span').textContent = 'Copied';
      clearTimeout(this.copyTimer);
      this.copyTimer = setTimeout(() => {
        copy.classList.remove('done');
        copy.querySelector('span').textContent = 'Copy';
      }, 1400);
    });

    container.querySelector('.export-preview').addEventListener('click', () => post({ type: 'action', id: 'exportPreview' }));

    this.zoomOutButton = container.querySelector('.zoom-out');
    this.zoomInButton = container.querySelector('.zoom-in');
    this.zoomLabel = container.querySelector('.zoom-reset');
    this.zoomOutButton.addEventListener('click', () => this.zoomBy(-1));
    this.zoomInButton.addEventListener('click', () => this.zoomBy(1));
    this.zoomLabel.addEventListener('click', () => this.zoomBy(0));
    this.setZoom(parseFloat(storage.get('previewZoom')) || 1);
    // Trackpad pinch arrives as ctrl+wheel (and as WebKit gesture events).
    container.addEventListener('wheel', (e) => {
      if (!e.ctrlKey || this.language !== 'markdown') return;
      e.preventDefault();
      this.setZoom(this.zoom * Math.exp(-e.deltaY * 0.01), e);
    }, { passive: false });
    container.addEventListener('gesturestart', (e) => { e.preventDefault(); this.gestureZoom = this.zoom; });
    container.addEventListener('gesturechange', (e) => {
      e.preventDefault();
      if (this.language === 'markdown') this.setZoom(this.gestureZoom * e.scale, e);
    });
    // Whether the last click landed in the preview; ⌘+/⌘− then zoom it instead of the editor font.
    this.active = false;
    container.addEventListener('pointerdown', () => { this.active = true; }, true);

    this.markdownEl.addEventListener('click', (e) => {
      const link = e.target.closest('a[href]');
      if (!link) return;
      e.preventDefault();
      const href = link.getAttribute('href');
      if (href.startsWith('#')) {
        this.markdownEl.querySelector(`[id="${CSS.escape(decodeURIComponent(href.slice(1)))}"]`)?.scrollIntoView();
      } else {
        post({ type: 'openURL', url: link.href });
      }
    });
  }

  /** `step` is +1 / -1 for the next zoom stop up or down, 0 for actual size. */
  zoomBy(step) {
    if (step === 0) return this.setZoom(1);
    const stops = step > 0 ? ZOOM_STEPS.filter((z) => z > this.zoom + 0.001) : ZOOM_STEPS.filter((z) => z < this.zoom - 0.001).reverse();
    this.setZoom(stops[0] ?? this.zoom);
  }

  /** Scales the rendered Markdown; with a pointer event the point under it stays put. */
  setZoom(zoom, anchor) {
    const next = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, Math.round(zoom * 100) / 100));
    const previous = this.zoom ?? 1;
    this.zoom = next;
    const scroller = this.container;
    const rect = scroller.getBoundingClientRect();
    const y = anchor ? anchor.clientY - rect.top : 0;
    const ratio = previous ? next / previous : 1;
    const top = (scroller.scrollTop + y) * ratio - y;
    this.markdownEl.style.zoom = next === 1 ? '' : String(next);
    if (previous !== next) scroller.scrollTop = top;
    this.zoomLabel.textContent = `${Math.round(next * 100)}%`;
    this.zoomLabel.title = next === 1 ? 'Actual size (⌘0)' : 'Reset to actual size (⌘0)';
    this.zoomOutButton.disabled = next <= ZOOM_MIN;
    this.zoomInButton.disabled = next >= ZOOM_MAX;
    storage.set('previewZoom', String(next));
  }

  /** `doc` is a CodeMirror `Text` (or a string); large documents are only converted as far as needed. */
  render(language, doc) {
    const started = performance.now();
    if (typeof doc === 'string') doc = { toString: () => doc, length: doc.length, string: doc };
    if (language !== this.language) this.blocks = [];
    this.language = language;
    this.container.dataset.lang = language;
    this.markdownEl.hidden = language !== 'markdown';
    this.frame.hidden = language !== 'html';
    this.tableEl.hidden = language !== 'csv' && language !== 'tsv';
    this.specFrame.hidden = language !== 'openapi';
    if (language === 'openapi') {
      this.renderSpec(doc.toString());
    } else if (language === 'markdown') {
      this.blocks = patchMarkdown(this.markdownEl, doc.toString(), this.blocks ?? []);
      renderDiagrams(this.markdownEl);
    } else if (language === 'html') {
      this.frame.srcdoc = doc.toString();
    } else {
      renderTable(this.tableEl, tableSource(doc), language === 'tsv' ? '\t' : null, doc.lines);
    }
    this.lastRenderMs = performance.now() - started;
  }

  /** Puts the rendered Markdown on the clipboard as rich text (HTML + RTF) with a plain-text fallback. */
  copyRich(text) {
    const source = document.createElement('article');
    source.innerHTML = text == null ? this.markdownEl.innerHTML : renderMarkdown(text);
    post({ type: 'copyRich', html: inlineStyles(source).innerHTML, text: plainText(source) });
  }

  /**
   * The rendered Markdown as a standalone, light-themed HTML page: styles are inline and diagrams are SVG drawn in the
   * light theme. `mode` 'print' (PDF) keeps blocks from breaking across pages; 'html' centres a readable column.
   */
  async printableDocument(text, title, mode = 'print') {
    const source = document.createElement('article');
    source.innerHTML = diagramPlaceholders(renderMarkdown(text));
    const figures = [...source.querySelectorAll('.mermaid-diagram')];
    if (figures.length) await drawDiagrams(figures, 'default');
    const body = inlineStyles(source).innerHTML;
    const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
    return `<!doctype html><html><head><meta charset="utf-8"><title>${escape(title)}</title><style>
      ${mode === 'html' ? 'body { max-width: 860px; margin: 40px auto !important; padding: 0 28px 40px; }' : ''}
      html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      body { margin: 0; font: 11pt/1.55 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; color: #1f2328; background: #fff; }
      h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.3em 0 .55em; break-after: avoid; }
      h1:first-child, h2:first-child { margin-top: 0; }
      p, ul, ol, pre, table, blockquote { margin: 0 0 .9em; }
      pre, table, blockquote, img, figure, .mermaid-diagram, tr { break-inside: avoid; }
      a { color: #0969da; text-decoration: none; }
      hr { border: 0; border-top: 1px solid #d1d9e0; margin: 1.4em 0; }
      img { max-width: 100%; }
      .mermaid-diagram { text-align: center; margin: 0 0 1em; }
      .mermaid-diagram svg { max-width: 100%; height: auto; }
      .mermaid-error { color: #cf222e; font-size: 10pt; }
      input[type=checkbox] { margin: 0 .4em 0 0; }
    </style></head><body>${body}</body></html>`;
  }

  /** OpenAPI specs open in Swagger UI, Scalar or Kong's renderer, inside their own page (their styles are global). */
  renderSpec(text) {
    this.specText = text;
    const src = `viewer.html?${this.specViewer}`;
    if (this.specFrame.getAttribute('src') !== src) {
      this.specReady = false;
      this.specFrame.setAttribute('src', src);
    } else if (this.specReady) {
      this.postSpec();
    }
  }

  postSpec() {
    if (this.specText == null) return;
    this.specFrame.contentWindow?.postMessage({ type: 'spec', options: { viewer: this.specViewer, spec: this.specText } }, '*');
  }

  /** 'swagger', 'scalar' or 'kong'; each gets a fresh page so their styles don't mix. */
  setSpecViewer(viewer) {
    if (viewer === this.specViewer) return;
    this.specViewer = viewer;
    if (this.language === 'openapi' && this.specText != null) this.renderSpec(this.specText);
  }

  /** Renders once typing pauses; slow renders push the next one further out so typing stays responsive. */
  scheduleRender(language, doc) {
    clearTimeout(this.timer);
    // HTML previews load asynchronously in the iframe, so their cost is estimated from the size instead.
    const delay = Math.min(2000, Math.max(150, (this.lastRenderMs ?? 0) * 3, (doc.length ?? 0) / 10_000));
    this.timer = setTimeout(() => this.render(language, doc), delay);
  }

  /** Keeps the preview roughly aligned with the editor scroll position (Markdown only). */
  syncScroll(ratio) {
    if (this.language !== 'markdown') return;
    const el = this.container;
    el.scrollTop = ratio * (el.scrollHeight - el.clientHeight);
  }
}

function renderMarkdown(text) {
  return DOMPurify.sanitize(marked.parse(text, { async: false }));
}

const MAX_MARKDOWN_PREVIEW = 1_000_000;

// ---------- Mermaid diagrams ----------

const darkQuery = window.matchMedia('(prefers-color-scheme: dark)');
const diagramCache = new Map(); // theme + source -> svg markup or { error }
let mermaidLoading = null;
let diagramCounter = 0;

/** Mermaid is large, so it's only loaded (from the app bundle) once a document contains a diagram. */
function loadMermaid() {
  mermaidLoading ??= new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = 'mermaid.min.js';
    script.onload = () => resolve(window.mermaid);
    script.onerror = () => { mermaidLoading = null; reject(new Error('Mermaid could not be loaded')); };
    document.head.appendChild(script);
  });
  return mermaidLoading;
}

/** Turns ```mermaid code blocks in rendered HTML into empty diagram elements that hold the source. */
function diagramPlaceholders(html) {
  if (!html.includes('language-mermaid')) return html;
  const template = document.createElement('template');
  template.innerHTML = html;
  template.content.querySelectorAll('pre > code.language-mermaid').forEach((code) => {
    const figure = document.createElement('div');
    figure.className = 'mermaid-diagram';
    figure.dataset.source = code.textContent;
    code.parentElement.replaceWith(figure);
  });
  return template.innerHTML;
}

/** Draws diagrams that haven't been drawn yet (unchanged parts of the preview keep theirs). */
function renderDiagrams(root) {
  const pending = [...root.querySelectorAll('.mermaid-diagram:not([data-drawn])')];
  if (pending.length) drawDiagrams(pending);
}

// Mermaid renders one diagram at a time; overlapping renders (typing, theme changes) wait their turn.
let drawing = Promise.resolve();
/** `theme` set: draws into elements that aren't in the page (exports), in that theme. */
function drawDiagrams(figures, theme) {
  drawing = drawing.then(() => drawNow(figures, theme));
  return drawing;
}

async function drawNow(figures, exportTheme) {
  const theme = exportTheme ?? (darkQuery.matches ? 'dark' : 'default');
  let mermaid;
  try {
    mermaid = await loadMermaid();
  } catch (e) {
    figures.forEach((f) => showDiagramError(f, e.message));
    return;
  }
  mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme });
  for (const figure of figures) {
    const source = figure.dataset.source;
    const key = theme + '\u0000' + source;
    let result = diagramCache.get(key);
    if (result === undefined) {
      try {
        result = (await mermaid.render(`mermaid-${++diagramCounter}`, source)).svg;
      } catch (e) {
        result = { error: String(e?.message || e).split('\n')[0] };
        document.getElementById(`dmermaid-${diagramCounter}`)?.remove();
      }
      if (diagramCache.size > 200) diagramCache.delete(diagramCache.keys().next().value);
      diagramCache.set(key, result);
    }
    // The preview may have been re-rendered (and this element replaced) while the diagram was drawn.
    if (!figure.isConnected && !exportTheme) continue;
    figure.dataset.drawn = '';
    if (typeof result === 'string') figure.innerHTML = result;
    else showDiagramError(figure, result.error);
  }
}

function showDiagramError(figure, message) {
  figure.replaceChildren();
  const error = document.createElement('div');
  error.className = 'mermaid-error';
  error.textContent = `Mermaid: ${message}`;
  const pre = document.createElement('pre');
  pre.textContent = figure.dataset.source;
  figure.append(error, pre);
}

darkQuery.addEventListener('change', () => {
  const figures = [...document.querySelectorAll('.markdown-body .mermaid-diagram')];
  if (figures.length) drawDiagrams(figures);
});

const headingId = (h) => h.textContent.trim().toLowerCase().replace(/[^\w\- ]/g, '').replace(/\s+/g, '-');

/**
 * Splits Markdown into runs of whole blocks of about `size` characters. Only blank lines followed by
 * unindented text that can't continue the previous block are used as cut points (never inside fenced
 * code, HTML comments or raw `<pre>`/`<script>`/`<style>` blocks, nor before list items or block quotes).
 */
function markdownChunks(text, size = 1024) {
  const chunks = [];
  let start = 0, fence = null, raw = null, blank = false;
  let pos = 0;
  while (pos < text.length) {
    let end = text.indexOf('\n', pos);
    if (end < 0) end = text.length;
    const line = text.slice(pos, end);
    if (fence) {
      if (line.trimStart().startsWith(fence) && line.trim().replace(/[`~]/g, '') === '') fence = null;
    } else if (raw) {
      if (raw.test(line)) raw = null;
    } else {
      const isBlank = line.trim() === '';
      if (blank && !isBlank && pos - start >= size && /^[^\s>*+\-|\d<]/.test(line)) {
        chunks.push(text.slice(start, pos));
        start = pos;
      }
      blank = isBlank;
      const opening = /^ {0,3}(`{3,}|~{3,})/.exec(line);
      if (opening) fence = opening[1];
      else if (/^ {0,3}<!--/.test(line) && !line.includes('-->')) raw = /-->/;
      else {
        const tag = /^ {0,3}<(pre|script|style|textarea)\b/i.exec(line);
        if (tag && !new RegExp(`</${tag[1]}>`, 'i').test(line)) raw = new RegExp(`</${tag[1]}>`, 'i');
      }
    }
    pos = end + 1;
  }
  if (start < text.length) chunks.push(text.slice(start));
  return chunks;
}

/** Reference link definitions anywhere in the document, so chunks lexed on their own can resolve them. */
function linkDefinitions(text) {
  const links = {};
  for (const m of text.matchAll(/^ {0,3}\[([^\]\n]+)\]:[ \t]*<?([^\s>]+)>?(?:[ \t]+["'(]([^\n]*?)["')])?[ \t]*$/gm)) {
    const tag = m[1].toLowerCase().replace(/\s+/g, ' ');
    if (!(tag in links)) links[tag] = { href: m[2], title: m[3] };
  }
  return links;
}

/**
 * Re-renders only the chunks of Markdown that changed since the last render and swaps just their nodes,
 * so typing in a long document doesn't rebuild (and re-lay out) the whole preview. Lexing in small chunks
 * also keeps parsing linear: marked's lexer slows down quadratically with document size in Safari.
 * `previous` is the last result: one `{ key, html, nodes }` per chunk.
 */
function patchMarkdown(el, text, previous) {
  const linkMap = linkDefinitions(text);
  const links = JSON.stringify(linkMap);
  const cached = new Map(previous.map((b) => [b.key, b.html]));
  const all = markdownChunks(text);
  let shown = 0;
  const limit = all.findIndex((c) => (shown += c.length) > MAX_MARKDOWN_PREVIEW);
  const chunks = limit < 0 ? all : all.slice(0, Math.max(1, limit));
  const next = chunks.map((chunk) => {
    const key = links + '\u0000' + chunk;
    let html = cached.get(key);
    if (html === undefined) {
      const lexer = new Lexer();
      Object.assign(lexer.tokens.links, linkMap);
      html = diagramPlaceholders(DOMPurify.sanitize(marked.parser(lexer.lex(chunk))));
    }
    return { key, html, nodes: null };
  });
  if (chunks.length < all.length) {
    const kb = (n) => Math.round(n / 1000).toLocaleString();
    const rendered = chunks.reduce((n, c) => n + c.length, 0);
    const html = `<p class="preview-note">Preview shows the first ${kb(rendered)} KB of ${kb(text.length)} KB.</p>`;
    next.push({ key: '\u0001' + html, html, nodes: null });
  }
  const old = previous.every((b) => b.nodes?.every((n) => n.parentNode === el)) ? previous : [];
  if (old.length === 0) el.replaceChildren();

  let start = 0;
  while (start < old.length && start < next.length && old[start].key === next[start].key) {
    next[start].nodes = old[start].nodes;
    start++;
  }
  let oldEnd = old.length, newEnd = next.length;
  while (oldEnd > start && newEnd > start && old[oldEnd - 1].key === next[newEnd - 1].key) {
    next[--newEnd].nodes = old[--oldEnd].nodes;
  }
  for (let i = start; i < oldEnd; i++) old[i].nodes.forEach((n) => n.remove());
  const anchor = next.slice(newEnd).flatMap((b) => b.nodes)[0] ?? null;
  for (let i = start; i < newEnd; i++) {
    const template = document.createElement('template');
    template.innerHTML = next[i].html;
    next[i].nodes = [...template.content.childNodes];
    template.content.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach((h) => { h.id = headingId(h); });
    el.insertBefore(template.content, anchor);
  }
  return next;
}

/** The part of a CSV/TSV document the table shows (its first rows), without converting all of it. */
function tableSource(doc) {
  if (doc.string !== undefined) return doc.string;
  const lines = Math.min(doc.lines, MAX_TABLE_ROWS + 1);
  return doc.sliceString(0, doc.line(lines).to);
}

/** Text as it reads on screen, for apps that only take plain text. */
function plainText(el) {
  const holder = document.createElement('div');
  holder.style.cssText = 'position:fixed;left:-10000px;top:0;width:800px;white-space:normal';
  holder.appendChild(el.cloneNode(true));
  document.body.appendChild(holder);
  const text = holder.innerText;
  holder.remove();
  return text.trim();
}

/** Mail, Notes, Docs and Slack ignore stylesheets on paste, so the look goes inline. */
function inlineStyles(root) {
  const el = root.cloneNode(true);
  const mono = 'font-family: Menlo, Monaco, monospace;';
  const set = (selector, css) => el.querySelectorAll(selector).forEach((n) => { n.style.cssText += css; });
  set('pre', `${mono} background:#f6f8fa; padding:10px 12px; border-radius:6px; font-size:12px; white-space:pre-wrap;`);
  set('code', `${mono} font-size:90%;`);
  set(':not(pre) > code', 'background:#f0f2f4; padding:1px 4px; border-radius:4px;');
  set('blockquote', 'margin:0; padding:0 1em; color:#59636e; border-left:4px solid #d1d9e0;');
  set('table', 'border-collapse:collapse;');
  set('th, td', 'border:1px solid #d1d9e0; padding:5px 10px; text-align:left;');
  set('th', 'background:#f6f8fa; font-weight:600;');
  set('h1, h2', 'border-bottom:1px solid #d1d9e0; padding-bottom:.3em;');
  set('img', 'max-width:100%;');
  return el;
}

const MAX_TABLE_ROWS = 5000;

/** Spreadsheet-style table for CSV/TSV: sticky header, row numbers, numeric columns right-aligned. */
function renderTable(container, text, fixedDelimiter, totalLines = 0) {
  container.replaceChildren();
  const delimiter = fixedDelimiter ?? detectDelimiter(text) ?? ',';
  const rows = parseCSV(text, delimiter).filter((r) => !(r.length === 1 && r[0] === ''));
  const summary = document.createElement('div');
  summary.className = 'table-summary';
  container.appendChild(summary);
  if (rows.length === 0) {
    summary.textContent = fixedDelimiter === '\t'
      ? 'Paste tab-separated rows (for example, copied from a spreadsheet) to fill the table.'
      : 'Paste comma-separated rows, or cells copied from a spreadsheet; they are converted to this file\'s delimiter.';
    return;
  }
  const columns = Math.max(...rows.slice(0, MAX_TABLE_ROWS).map((r) => r.length));
  const [header, ...body] = rows;
  const numeric = Array.from({ length: columns }, (_, c) => {
    const values = body.slice(0, 500).map((r) => (r[c] ?? '').trim()).filter((v) => v !== '');
    return values.length > 0 && values.filter((v) => /^[-+]?[$€£]?\d[\d,]*(\.\d+)?%?$/.test(v)).length >= values.length * 0.8;
  });
  const ragged = rows.some((r) => r.length !== columns);
  // Beyond the rows shown only lines are counted (quoted fields spanning lines make this approximate).
  const truncated = totalLines > MAX_TABLE_ROWS + 1;
  const count = truncated ? totalLines - 1 : body.length;
  summary.textContent = `${truncated ? '~' : ''}${count.toLocaleString()} row${count === 1 ? '' : 's'} × ${columns} column${columns === 1 ? '' : 's'}`
    + ` · ${delimiterName(delimiter)}-separated${ragged ? ' · some rows have fewer fields' : ''}`
    + (truncated || rows.length > MAX_TABLE_ROWS ? ` · showing the first ${MAX_TABLE_ROWS.toLocaleString()}` : '');

  const table = document.createElement('table');
  const thead = table.createTHead().insertRow();
  const corner = document.createElement('th');
  corner.className = 'row-number';
  thead.appendChild(corner);
  for (let c = 0; c < columns; c++) {
    const th = document.createElement('th');
    th.textContent = header[c] ?? '';
    if (numeric[c]) th.className = 'num';
    thead.appendChild(th);
  }
  const tbody = table.createTBody();
  const shown = body.slice(0, MAX_TABLE_ROWS - 1);
  const scroller = document.createElement('div');
  scroller.className = 'table-scroll';
  scroller.appendChild(table);
  container.appendChild(scroller);

  // Rows are added in chunks as the table scrolls, so re-rendering while typing stays cheap.
  let added = 0;
  const addRows = () => {
    const end = Math.min(shown.length, added + TABLE_CHUNK);
    for (; added < end; added++) {
      const row = shown[added];
      const tr = tbody.insertRow();
      const n = document.createElement('th');
      n.className = 'row-number';
      n.textContent = String(added + 1);
      tr.appendChild(n);
      for (let c = 0; c < columns; c++) {
        const td = tr.insertCell();
        const value = row[c];
        if (value === undefined) td.className = 'missing';
        else {
          td.textContent = value;
          if (numeric[c]) td.className = 'num';
        }
      }
    }
  };
  addRows();
  scroller.addEventListener('scroll', () => {
    if (added < shown.length && scroller.scrollTop + scroller.clientHeight > scroller.scrollHeight - 800) addRows();
  });
}

const TABLE_CHUNK = 500;
