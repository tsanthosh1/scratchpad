import { EditorView, lineNumbers, highlightSpecialChars, highlightActiveLine } from '@codemirror/view';
import { EditorState, Compartment } from '@codemirror/state';
import { foldGutter, bracketMatching } from '@codemirror/language';
import { search, highlightSelectionMatches } from '@codemirror/search';
import { storage } from './storage.js';

const post = (msg) => window.webkit?.messageHandlers?.bridge?.postMessage(msg);

export const icons = {
  copy: '<svg viewBox="0 0 16 16" style="fill:none;stroke:currentColor;stroke-width:1.4"><rect x="5.5" y="5.5" width="8.5" height="8.5" rx="1.6"/><path d="M10.5 5.5V3.6A1.6 1.6 0 0 0 8.9 2H3.6A1.6 1.6 0 0 0 2 3.6v5.3a1.6 1.6 0 0 0 1.6 1.6h1.9"/></svg>',
  check: '<svg viewBox="0 0 16 16"><path d="M13.8 4.2a.75.75 0 0 1 0 1.06l-6.5 6.5a.75.75 0 0 1-1.06 0l-3.5-3.5a.75.75 0 1 1 1.06-1.06l2.97 2.97 5.97-5.97a.75.75 0 0 1 1.06 0z"/></svg>',
  open: '<svg viewBox="0 0 16 16"><path d="M9 2h4.25c.41 0 .75.34.75.75V7a.75.75 0 0 1-1.5 0V4.56L8.03 9.03a.75.75 0 0 1-1.06-1.06l4.47-4.47H9A.75.75 0 0 1 9 2zM3.5 4A1.5 1.5 0 0 0 2 5.5v7A1.5 1.5 0 0 0 3.5 14h7a1.5 1.5 0 0 0 1.5-1.5V10a.75.75 0 0 0-1.5 0v2.5h-7v-7H6A.75.75 0 0 0 6 4H3.5z"/></svg>',
  terminal: '<svg viewBox="0 0 16 16"><path d="M2.5 2h11A1.5 1.5 0 0 1 15 3.5v9a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 1 12.5v-9A1.5 1.5 0 0 1 2.5 2zm0 1.5v9h11v-9h-11zm2.28 1.97 2.25 2.25a.75.75 0 0 1 0 1.06l-2.25 2.25a.75.75 0 1 1-1.06-1.06L5.44 8.25 3.72 6.53a.75.75 0 0 1 1.06-1.06zM8 10h3.25a.75.75 0 0 1 0 1.5H8A.75.75 0 0 1 8 10z"/></svg>',
  wrap: '<svg viewBox="0 0 16 16"><path d="M2 3.75A.75.75 0 0 1 2.75 3h10.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 3.75zm0 4A.75.75 0 0 1 2.75 7h8.5a2.75 2.75 0 0 1 0 5.5H9.56l.72.72a.75.75 0 1 1-1.06 1.06l-2-2a.75.75 0 0 1 0-1.06l2-2a.75.75 0 1 1 1.06 1.06l-.72.72h1.69a1.25 1.25 0 0 0 0-2.5h-8.5A.75.75 0 0 1 2 7.75zM2.75 11h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1 0-1.5z"/></svg>',
  close: '<svg viewBox="0 0 16 16"><path d="M3.72 3.72a.75.75 0 0 1 1.06 0L8 6.94l3.22-3.22a.75.75 0 1 1 1.06 1.06L9.06 8l3.22 3.22a.75.75 0 1 1-1.06 1.06L8 9.06l-3.22 3.22a.75.75 0 0 1-1.06-1.06L6.94 8 3.72 4.78a.75.75 0 0 1 0-1.06z"/></svg>',
  stop: '<svg viewBox="0 0 16 16"><rect x="4" y="4" width="8" height="8" rx="1.5"/></svg>',
  play: '<svg viewBox="0 0 16 16"><path d="M5 3.2v9.6a.6.6 0 0 0 .9.5l7.4-4.8a.6.6 0 0 0 0-1L5.9 2.7a.6.6 0 0 0-.9.5z"/></svg>',
  alert: '<svg viewBox="0 0 16 16"><path d="M8 1.5a6.5 6.5 0 1 1 0 13 6.5 6.5 0 0 1 0-13zM8 4a.75.75 0 0 0-.75.75v3.5a.75.75 0 0 0 1.5 0v-3.5A.75.75 0 0 0 8 4zm0 7.5a.9.9 0 1 0 0-1.8.9.9 0 0 0 0 1.8z"/></svg>',
};

export const el = (tag, className, html) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (html != null) node.innerHTML = html;
  return node;
};

export const toneOf = (r) => {
  if (!r || r.error) return 'error';
  if (r.status >= 500) return 'error';
  if (r.status >= 400) return 'warn';
  if (r.status >= 300) return 'redirect';
  return 'ok';
};

export const formatElapsed = (ms) => (ms < 1000 ? `${ms} ms` : `${(ms / 1000).toFixed(2)} s`);

// A run is `{ entries: [{ request, result?, pending, startedAt }], selected, pinned }`, kept per scratch.

/** `requests`: [{ title, name, method, url, line }] */
export function newRun(requests) {
  const run = { entries: requests.map((request) => ({ request, pending: true, startedAt: 0 })), selected: 0, pinned: false };
  if (run.entries[0]) run.entries[0].startedAt = performance.now();
  return run;
}

export function applyResult(run, index, result) {
  const entry = run?.entries[index];
  if (!entry) return;
  entry.pending = false;
  entry.result = result;
  const next = run.entries[index + 1];
  if (next) next.startedAt = performance.now();
  // Show the newest result unless the user picked a request themselves.
  if (!run.pinned) run.selected = index;
}

export function finishRun(run, cancelled) {
  for (const entry of run?.entries ?? []) {
    if (entry.pending) {
      entry.pending = false;
      entry.result = cancelled ? { error: 'Cancelled', cancelled: true, curl: null } : { error: 'No response' };
    }
  }
}

/**
 * Postman-style response viewer for HTTP scratches. Each run is a list of entries
 * `{ request, result?, pending }`; the selected entry is shown with Body / Headers tabs.
 */
export class ResponsePanel {
  constructor(root, { languageSupport, baseExtensions, onClose }) {
    this.root = root;
    this.languageSupport = languageSupport;
    this.baseExtensions = baseExtensions;
    this.onClose = onClose;
    this.run = null;
    this.tab = 'body';
    this.wrap = storage.get('responseWrap') === '1';
    this.bodyView = null;
    this.langConf = new Compartment();
    this.wrapConf = new Compartment();
    this.themeConf = new Compartment();
    this.tickTimer = 0;
    this.build();
  }

  build() {
    const r = this.root;
    r.innerHTML = '';
    this.requestsBar = el('div', 'rsp-requests');
    this.summary = el('div', 'rsp-summary');
    this.urlLine = el('div', 'rsp-url');
    const tabs = el('div', 'rsp-tabs');
    this.bodyTab = this.tabButton('Body', 'body');
    this.headersTab = this.tabButton('Headers', 'headers');
    tabs.append(this.bodyTab, this.headersTab, el('span', 'rsp-spacer'));
    this.wrapButton = this.iconButton(icons.wrap, 'Soft-wrap long lines', () => this.toggleWrap());
    this.wrapButton.classList.toggle('on', this.wrap);
    tabs.append(this.wrapButton);
    this.content = el('div', 'rsp-content');
    this.bodyHost = el('div', 'rsp-body');
    this.headersHost = el('div', 'rsp-headers');
    this.message = el('div', 'rsp-message');
    this.content.append(this.bodyHost, this.headersHost, this.message);
    this.tabsBar = tabs;
    r.append(this.requestsBar, this.summary, this.urlLine, tabs, this.content);
    this.renderEmpty();
  }

  tabButton(label, id) {
    const b = el('button', 'rsp-tab');
    b.type = 'button';
    b.innerHTML = `<span>${label}</span><span class="count"></span>`;
    b.addEventListener('click', () => this.selectTab(id));
    return b;
  }

  iconButton(icon, title, onClick, label) {
    const b = el('button', label ? 'rsp-btn' : 'rsp-btn icon', icon + (label ? `<span>${label}</span>` : ''));
    b.type = 'button';
    b.title = title;
    b.addEventListener('click', (e) => {
      e.preventDefault();
      onClick(b);
    });
    return b;
  }

  get entry() {
    return this.run?.entries[this.run.selected] ?? null;
  }

  // ---------- state changes ----------

  select(index) {
    if (!this.run?.entries[index]) return;
    this.run.selected = index;
    this.run.pinned = true;
    this.render();
  }

  /** Selects the entry for the request whose line starts at `pos`. */
  selectLine(pos) {
    const index = this.run?.entries.findIndex((e) => e.request.line === pos) ?? -1;
    if (index >= 0) this.select(index);
  }

  selectTab(tab) {
    this.tab = tab;
    this.render();
  }

  toggleWrap() {
    this.wrap = !this.wrap;
    storage.set('responseWrap', this.wrap ? '1' : '0');
    this.wrapButton.classList.toggle('on', this.wrap);
    this.bodyView?.dispatch({ effects: this.wrapConf.reconfigure(this.wrap ? EditorView.lineWrapping : []) });
  }

  /** Saved/restored per scratch by the editor. */
  snapshot() {
    return this.run;
  }

  restore(run) {
    this.run = run ?? null;
    this.render();
  }

  /** Rebuilds the body view, e.g. after font settings change. */
  invalidate() {
    this.bodyResult = null;
    if (this.run) this.render();
  }

  refreshTheme(themeExtension) {
    this.themeExtension = themeExtension;
    this.bodyView?.dispatch({ effects: this.themeConf.reconfigure(themeExtension) });
  }

  // ---------- rendering ----------

  renderEmpty() {
    this.requestsBar.hidden = true;
    this.urlLine.hidden = true;
    this.tabsBar.hidden = true;
    this.summary.innerHTML = '';
    this.summary.append(el('span', 'rsp-title', 'Response'), el('span', 'rsp-spacer'), this.closeButton());
    this.showMessage(`
      <div class="rsp-empty">
        <div class="rsp-empty-icon">${icons.play}</div>
        <div class="rsp-empty-title">No response yet</div>
        <div class="rsp-empty-hint">Click <b>▶</b> next to a request or press the Run shortcut.</div>
      </div>`);
  }

  closeButton() {
    return this.iconButton(icons.close, 'Close response panel', () => this.onClose?.());
  }

  render() {
    clearInterval(this.tickTimer);
    const entry = this.entry;
    if (!entry) return this.renderEmpty();
    this.renderRequests();
    this.renderSummary(entry);
    const { request, result, pending } = entry;
    this.urlLine.hidden = false;
    this.urlLine.innerHTML = '';
    const method = el('span', `rsp-method m-${request.method.toLowerCase()}`);
    method.textContent = request.method;
    const url = el('span', 'rsp-url-text');
    url.textContent = result?.redirectedTo ? `${request.url}  →  ${result.redirectedTo}` : request.url;
    url.title = url.textContent;
    this.urlLine.append(method, url);

    if (pending) {
      this.tabsBar.hidden = true;
      this.showMessage(`
        <div class="rsp-loading">
          <div class="rsp-spinner"></div>
          <div class="rsp-loading-text">Sending request…</div>
          <div class="rsp-loading-time">0 ms</div>
        </div>`);
      const time = this.message.querySelector('.rsp-loading-time');
      const cancel = this.iconButton(icons.stop, 'Cancel the request', () => post({ type: 'action', id: 'stop' }), 'Cancel');
      cancel.classList.add('danger');
      this.message.querySelector('.rsp-loading').append(cancel);
      this.tickTimer = setInterval(() => {
        time.textContent = formatElapsed(Math.round(performance.now() - entry.startedAt));
      }, 50);
      return;
    }

    if (result?.error) {
      this.tabsBar.hidden = true;
      const box = el('div', result.cancelled ? 'rsp-error cancelled' : 'rsp-error');
      box.innerHTML = `<div class="rsp-error-icon">${icons.alert}</div>`;
      const title = el('div', 'rsp-error-title');
      title.textContent = result.cancelled ? 'Request cancelled' : 'Request failed';
      const detail = el('div', 'rsp-error-detail');
      detail.textContent = result.cancelled ? 'The request was stopped before a response arrived.' : result.error;
      const retry = this.iconButton(icons.play, 'Send the request again',
        () => post({ type: 'runRequest', offset: request.line }), 'Retry');
      retry.classList.add('primary');
      box.append(title, detail, retry);
      this.showMessage('');
      this.message.append(box);
      return;
    }

    this.tabsBar.hidden = false;
    this.headersTab.querySelector('.count').textContent = String(result.headers?.length ?? 0);
    this.bodyTab.classList.toggle('active', this.tab === 'body');
    this.headersTab.classList.toggle('active', this.tab === 'headers');
    this.wrapButton.hidden = this.tab !== 'body' || result.body == null;
    if (this.tab === 'headers') this.renderHeaders(result);
    else this.renderBody(result);
  }

  renderRequests() {
    const entries = this.run.entries;
    this.requestsBar.hidden = entries.length < 2;
    if (entries.length < 2) return;
    this.requestsBar.innerHTML = '';
    entries.forEach((entry, i) => {
      const b = el('button', `rsp-req${i === this.run.selected ? ' active' : ''}`);
      b.type = 'button';
      const tone = entry.pending ? 'pending' : toneOf(entry.result);
      const status = entry.pending ? '' : entry.result?.error ? (entry.result.cancelled ? '—' : 'ERR') : entry.result.status;
      b.innerHTML = `<span class="rsp-req-dot tone-${tone}"></span><span class="rsp-req-name"></span><span class="rsp-req-status tone-${tone}">${status}</span>`;
      b.querySelector('.rsp-req-name').textContent = entry.request.name || `${entry.request.method} ${shortPath(entry.request.url)}`;
      b.title = entry.request.title;
      b.addEventListener('click', () => this.select(i));
      this.requestsBar.append(b);
    });
    this.requestsBar.querySelector('.active')?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }

  renderSummary(entry) {
    const s = this.summary;
    s.innerHTML = '';
    const { result, pending } = entry;
    if (pending) {
      s.append(el('span', 'rsp-status tone-pending', '<span class="dot"></span>Pending'));
    } else if (result?.error) {
      s.append(el('span', 'rsp-status tone-error', `<span class="dot"></span>${result.cancelled ? 'Cancelled' : 'Error'}`));
    } else {
      const badge = el('span', `rsp-status tone-${toneOf(result)}`);
      badge.innerHTML = '<span class="dot"></span>';
      badge.append(`${result.status} ${result.reason}`);
      s.append(badge, metric('Time', formatElapsed(result.elapsedMs)), metric('Size', result.size));
    }
    s.append(el('span', 'rsp-spacer'));
    if (!pending && !result?.error) {
      if (result.body != null) {
        s.append(this.iconButton(icons.copy, 'Copy the response body', (b) => this.copy(b, result.body)));
        s.append(this.iconButton(icons.open, 'Open the body in a new scratch',
          () => post({ type: 'openResponse', text: result.body, language: result.language })));
      }
    }
    if (result?.curl) {
      s.append(this.iconButton(icons.terminal, 'Copy the request as a cURL command', (b) => this.copy(b, result.curl)));
    }
    s.append(el('span', 'rsp-divider'), this.closeButton());
  }

  copy(button, text) {
    post({ type: 'copyText', text });
    const original = button.innerHTML;
    button.classList.add('done');
    button.innerHTML = icons.check;
    setTimeout(() => {
      button.classList.remove('done');
      button.innerHTML = original;
    }, 1200);
  }

  renderBody(result) {
    this.headersHost.hidden = true;
    if (result.image) {
      this.bodyHost.hidden = true;
      this.showMessage('');
      const wrap = el('div', 'rsp-image');
      const img = document.createElement('img');
      img.src = result.image;
      img.alt = 'Response image';
      wrap.append(img);
      this.message.append(wrap);
      return;
    }
    if (result.body == null) {
      this.bodyHost.hidden = true;
      this.showMessage(`<div class="rsp-note">Binary body · ${result.size}${result.contentType ? ` · ${escapeHTML(result.contentType)}` : ''}</div>`);
      return;
    }
    if (result.body === '') {
      this.bodyHost.hidden = true;
      this.showMessage('<div class="rsp-note">Empty body</div>');
      return;
    }
    this.message.hidden = true;
    this.bodyHost.hidden = false;
    if (this.bodyView && this.bodyResult === result) return;
    this.bodyResult = result;
    const state = EditorState.create({
      doc: result.body + (result.truncated ? '\n\n… truncated — open it in a new scratch to see everything.' : ''),
      extensions: [
        lineNumbers(),
        foldGutter(),
        highlightSpecialChars(),
        highlightActiveLine(),
        highlightSelectionMatches(),
        bracketMatching(),
        search({ top: true }),
        EditorState.readOnly.of(true),
        this.baseExtensions(),
        this.themeConf.of(this.themeExtension ?? []),
        this.langConf.of(this.languageSupport(result.language)),
        this.wrapConf.of(this.wrap ? EditorView.lineWrapping : []),
        EditorView.theme({ '&': { height: '100%' }, '.cm-scroller': { overflow: 'auto' }, '&.cm-focused': { outline: 'none' } }),
      ],
    });
    if (this.bodyView) this.bodyView.setState(state);
    else this.bodyView = new EditorView({ state, parent: this.bodyHost });
  }

  renderHeaders(result) {
    this.bodyHost.hidden = true;
    this.message.hidden = true;
    this.headersHost.hidden = false;
    this.headersHost.innerHTML = '';
    const table = el('table', 'rsp-header-table');
    for (const [name, value] of result.headers ?? []) {
      const row = document.createElement('tr');
      const key = el('th');
      key.textContent = name;
      const val = el('td');
      val.textContent = value;
      const copyCell = el('td', 'copy');
      copyCell.append(this.iconButton(icons.copy, `Copy ${name}`, (b) => this.copy(b, value)));
      row.append(key, val, copyCell);
      table.append(row);
    }
    this.headersHost.append(table);
  }

  showMessage(html) {
    this.bodyHost.hidden = true;
    this.headersHost.hidden = true;
    this.message.hidden = false;
    this.message.innerHTML = html;
  }
}

function metric(label, value) {
  const m = el('span', 'rsp-metric');
  m.innerHTML = `<span class="k">${label}</span>`;
  const v = el('span', 'v');
  v.textContent = value;
  m.append(v);
  return m;
}

function shortPath(url) {
  try {
    const u = new URL(url);
    return u.pathname + u.search;
  } catch {
    return url;
  }
}

function escapeHTML(s) {
  return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
}
