import { MergeView, Chunk, Change, diff as computeDiff, goToNextChunk, goToPreviousChunk } from '@codemirror/merge';
import { EditorView, lineNumbers, highlightSpecialChars } from '@codemirror/view';
import { EditorState, Text } from '@codemirror/state';
import { foldGutter } from '@codemirror/language';
import { icons, el } from './response.js';
import { storage } from './storage.js';
import { parseDiff, serializeDiff } from './diffdoc.js';

const diffIcons = {
  whitespace: '<svg viewBox="0 0 16 16" style="fill:none;stroke:currentColor;stroke-width:1.5;stroke-linecap:round;stroke-linejoin:round"><path d="M2.5 8.5v3h11v-3"/></svg>',
  up: '<svg viewBox="0 0 16 16" style="fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round"><path d="M4 10l4-4 4 4"/></svg>',
  down: '<svg viewBox="0 0 16 16" style="fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round"><path d="M4 6l4 4 4-4"/></svg>',
  swap: '<svg viewBox="0 0 16 16" style="fill:none;stroke:currentColor;stroke-width:1.5;stroke-linecap:round;stroke-linejoin:round"><path d="M2.5 5.5h10M10 3l2.5 2.5L10 8M13.5 10.5h-10M6 8l-2.5 2.5L6 13"/></svg>',
  edit: '<svg viewBox="0 0 16 16" style="fill:none;stroke:currentColor;stroke-width:1.5;stroke-linecap:round;stroke-linejoin:round"><path d="M10.5 2.5l3 3-8 8H2.5v-3z"/></svg>',
  diff: '<svg viewBox="0 0 16 16" style="fill:none;stroke:currentColor;stroke-width:1.5;stroke-linecap:round"><rect x="1.75" y="2.5" width="12.5" height="11" rx="2"/><path d="M8 2.5v11M4 6h2M4 9h2M10 6h2M10 9h2"/></svg>',
};

// ---------- options shared by the compare overlay and diff scratches ----------

const listeners = new Set();
export const diffOptions = {
  get ignoreWhitespace() { return storage.get('diffIgnoreWhitespace') === '1'; },
  get wrap() { return storage.get('diffWrap') !== '0'; },
  set(key, value) {
    storage.set(key === 'wrap' ? 'diffWrap' : 'diffIgnoreWhitespace', value ? '1' : '0');
    for (const fn of listeners) fn();
  },
  subscribe(fn) { listeners.add(fn); },
};

// ---------- whitespace-insensitive diff ----------

const WS = /[ \t\r\f\v\u00a0]/;

function strip(s) {
  const map = [];
  const out = [];
  for (let i = 0; i < s.length; i++) {
    if (!WS.test(s[i])) {
      map.push(i);
      out.push(s[i]);
    }
  }
  return { text: out.join(''), map };
}

// Maps a range in the stripped text back to the original; insertions sit right after the previous kept character.
function span(m, from, to) {
  if (from === to) {
    const p = from === 0 ? 0 : m.map[from - 1] + 1;
    return [p, p];
  }
  return [m.map[from], m.map[to - 1] + 1];
}

/** Diffs with spaces and tabs removed (line breaks still count), then maps changes back to the real text. */
export function ignoreWhitespaceDiff(a, b) {
  const A = strip(a);
  const B = strip(b);
  return computeDiff(A.text, B.text, { scanLimit: 5000, timeout: 1500 }).map((c) => {
    const [fromA, toA] = span(A, c.fromA, c.toA);
    const [fromB, toB] = span(B, c.fromB, c.toB);
    return new Change(fromA, toA, fromB, toB);
  });
}

const diffConfig = (ignoreWhitespace) =>
  (ignoreWhitespace ? { override: ignoreWhitespaceDiff } : { scanLimit: 5000, timeout: 1500 });

const countLines = (doc, from, to) => {
  if (to <= from) return 0;
  const slice = doc.sliceString(from, Math.min(to, doc.length));
  return (slice.match(/\n/g)?.length ?? 0) + (to > doc.length ? 1 : 0);
};

/** Number of changed chunks plus removed/added line counts. */
export function diffStats(a, b, ignoreWhitespace) {
  const A = Text.of(a.split('\n'));
  const B = Text.of(b.split('\n'));
  const chunks = Chunk.build(A, B, diffConfig(ignoreWhitespace));
  let removed = 0;
  let added = 0;
  for (const c of chunks) {
    removed += countLines(A, c.fromA, c.toA);
    added += countLines(B, c.fromB, c.toB);
  }
  return { chunks: chunks.length, removed, added, identical: a === b };
}

function renderStats(node, stats) {
  node.classList.toggle('same', stats.chunks === 0);
  if (stats.chunks === 0) {
    node.textContent = stats.identical ? 'Identical' : 'No changes (whitespace only)';
    return;
  }
  node.innerHTML = `${stats.chunks} change${stats.chunks === 1 ? '' : 's'}`
    + `<span class="del">−${stats.removed}</span><span class="add">+${stats.added}</span>`;
}

function buildMerge(parent, { a, b, extensions, editable, onChange }) {
  const side = (doc) => ({
    doc,
    extensions: [
      extensions,
      diffOptions.wrap ? EditorView.lineWrapping : [],
      editable ? [] : [EditorState.readOnly.of(true), EditorView.editable.of(false)],
      onChange ? EditorView.updateListener.of((u) => { if (u.docChanged) onChange(); }) : [],
    ],
  });
  return new MergeView({
    a: side(a),
    b: side(b),
    parent,
    highlightChanges: true,
    gutter: true,
    collapseUnchanged: { margin: 3, minSize: 6 },
    diffConfig: diffConfig(diffOptions.ignoreWhitespace),
  });
}

function button(icon, title, onClick, label) {
  const b = el('button', 'rsp-btn' + (label ? '' : ' icon'), icon + (label ? `<span>${label}</span>` : ''));
  b.title = title;
  b.type = 'button';
  b.addEventListener('mousedown', (e) => e.preventDefault());
  b.addEventListener('click', () => onClick(b));
  return b;
}

/** "Ignore whitespace" and "Wrap" toggles, kept in sync with the shared options. */
function optionToggles() {
  const ws = button(diffIcons.whitespace, 'Ignore whitespace differences', () => diffOptions.set('ignoreWhitespace', !diffOptions.ignoreWhitespace), 'Whitespace');
  const wrap = button(icons.wrap, 'Wrap long lines', () => diffOptions.set('wrap', !diffOptions.wrap), 'Wrap');
  const sync = () => {
    ws.classList.toggle('on', diffOptions.ignoreWhitespace);
    ws.title = diffOptions.ignoreWhitespace ? 'Whitespace is ignored — click to compare it' : 'Ignore whitespace differences';
    wrap.classList.toggle('on', diffOptions.wrap);
  };
  sync();
  diffOptions.subscribe(sync);
  return [ws, wrap];
}

function navButtons(getView) {
  const go = (cmd) => {
    const v = getView();
    if (v) {
      cmd(v);
      v.focus();
    }
  };
  return [
    button(diffIcons.up, 'Previous change', () => go(goToPreviousChunk)),
    button(diffIcons.down, 'Next change', () => go(goToNextChunk)),
  ];
}

// ---------- compare overlay (two scratches, or a scratch and the clipboard) ----------

/** Read-only side-by-side comparison of two texts. */
export class DiffPanel {
  constructor(root, onClose) {
    this.root = root;
    this.onClose = onClose;
    this.view = null;
    this.spec = null;
    const header = root.querySelector('.diff-header');
    const tools = header.querySelector('.diff-tools');
    tools.append(...navButtons(() => this.view?.b), el('span', 'rsp-divider'), ...optionToggles());
    root.querySelector('.diff-close').addEventListener('click', () => this.close());
    diffOptions.subscribe(() => { if (this.isOpen) this.render(); });
    document.addEventListener('keydown', (e) => {
      if (this.isOpen && e.key === 'Escape') {
        e.preventDefault();
        this.close();
      }
    }, true);
  }

  get isOpen() {
    return this.view !== null;
  }

  open(spec) {
    this.spec = spec;
    this.root.querySelector('.diff-a').textContent = spec.aName;
    this.root.querySelector('.diff-b').textContent = spec.bName;
    this.render();
    this.root.hidden = false;
    document.body.classList.add('diffing');
  }

  render() {
    this.destroyView();
    const { aText, bText, extensions } = this.spec;
    const shared = [lineNumbers(), highlightSpecialChars(), foldGutter(), ...extensions];
    this.view = buildMerge(this.root.querySelector('.diff-body'), { a: aText, b: bText, extensions: shared, editable: false });
    renderStats(this.root.querySelector('.diff-stats'), diffStats(aText, bText, diffOptions.ignoreWhitespace));
  }

  destroyView() {
    if (this.view) {
      this.view.destroy();
      this.view = null;
    }
  }

  close() {
    if (!this.isOpen) return;
    this.destroyView();
    this.root.hidden = true;
    document.body.classList.remove('diffing');
    this.onClose?.();
  }
}

// ---------- diff scratches: two named sides with an edit view and a diff view ----------

export const SYNTAXES = [
  ['text', 'Plain Text'], ['json', 'JSON'], ['xml', 'XML'], ['html', 'HTML'], ['markdown', 'Markdown'],
  ['javascript', 'JavaScript'], ['typescript', 'TypeScript'], ['java', 'Java'], ['python', 'Python'],
  ['shell', 'Shell'], ['css', 'CSS'], ['sql', 'SQL'], ['yaml', 'YAML'], ['toml', 'TOML'],
  ['properties', 'Properties'], ['kotlin', 'Kotlin'], ['go', 'Go'], ['rust', 'Rust'], ['cpp', 'C / C++'],
];

export class DiffWorkspace {
  /**
   * deps.sideExtensions(syntax) — full editor extensions for an edit-view side.
   * deps.mergeExtensions(syntax) — extensions for the diff-view editors.
   * deps.languageEffect(syntax) — effect that swaps the syntax of an existing editor.
   * deps.onChange() — the document (either side, a name or the syntax) changed.
   * deps.onFocus(view) — an editor inside the workspace gained focus.
   */
  constructor(root, deps) {
    this.root = root;
    this.deps = deps;
    this.docs = new Map();
    this.id = null;
    this.entry = null;
    this.merge = null;
    this.lastFocus = null;
    this.statsTimer = 0;
    this.build();
    diffOptions.subscribe(() => {
      if (this.entry?.mode === 'diff') this.renderDiff();
      this.updateStats();
    });
  }

  build() {
    const bar = el('div', 'dd-bar');
    this.seg = el('div', 'dd-seg');
    this.editTab = button(diffIcons.edit, 'Edit both sides (⇧⌘V toggles)', () => this.setMode('edit'), 'Edit');
    this.diffTab = button(diffIcons.diff, 'Show the differences (⇧⌘V toggles)', () => this.setMode('diff'), 'Diff');
    this.seg.append(this.editTab, this.diffTab);

    this.syntax = el('select', 'dd-syntax');
    this.syntax.title = 'Syntax highlighting for both sides';
    for (const [value, label] of SYNTAXES) this.syntax.append(new Option(label, value));
    this.syntax.addEventListener('change', () => this.setSyntax(this.syntax.value));

    this.stats = el('span', 'diff-stats');
    this.nav = el('span', 'dd-nav');
    this.nav.append(...navButtons(() => this.merge?.b));
    const swap = button(diffIcons.swap, 'Swap left and right', () => this.swap());
    bar.append(this.seg, this.syntax, el('span', 'rsp-spacer'), this.stats, this.nav, swap,
      el('span', 'rsp-divider'), ...optionToggles());

    const names = el('div', 'dd-names');
    this.nameInputs = ['left', 'right'].map((side) => {
      const label = el('label', `dd-name ${side}`);
      const input = el('input');
      input.spellcheck = false;
      input.placeholder = side === 'left' ? 'Left name' : 'Right name';
      input.title = `Name of the ${side} side`;
      input.addEventListener('input', () => {
        if (!this.entry) return;
        this.entry[`${side}Name`] = input.value;
        this.deps.onChange();
      });
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === 'Escape') {
          e.preventDefault();
          this.activeView()?.focus();
        }
      });
      label.append(el('span', 'marker'), input);
      names.append(label);
      return input;
    });

    const body = el('div', 'dd-body');
    this.editBox = el('div', 'dd-edit');
    const left = el('div', 'dd-pane left');
    const right = el('div', 'dd-pane right');
    this.editBox.append(left, el('div', 'dd-gap'), right);
    this.diffBox = el('div', 'dd-diff');
    body.append(this.editBox, this.diffBox);
    this.root.append(bar, names, body);

    this.left = new EditorView({ parent: left });
    this.right = new EditorView({ parent: right });
    for (const v of [this.left, this.right]) this.trackFocus(v);
  }

  trackFocus(v) {
    v.contentDOM.addEventListener('focus', () => {
      this.lastFocus = v;
      this.deps.onFocus(v);
    });
  }

  // ---- documents ----

  isEntryText(entry, text) {
    return this.serializeEntry(entry) === text;
  }

  serializeEntry(entry) {
    const on = entry === this.entry;
    const [left, right] = on ? this.texts() : [entry.left.doc.toString(), entry.right.doc.toString()];
    return serializeDiff({ syntax: entry.syntax, leftName: entry.leftName, rightName: entry.rightName, left, right });
  }

  load(id, text) {
    this.stash();
    let entry = this.docs.get(id);
    if (!entry || !this.isEntryText(entry, text)) {
      const doc = parseDiff(text);
      entry = {
        ...doc,
        mode: entry?.mode ?? (doc.left && doc.right ? 'diff' : 'edit'),
        left: EditorState.create({ doc: doc.left, extensions: this.deps.sideExtensions(doc.syntax) }),
        right: EditorState.create({ doc: doc.right, extensions: this.deps.sideExtensions(doc.syntax) }),
      };
      this.docs.set(id, entry);
    }
    this.id = id;
    this.entry = entry;
    this.left.setState(entry.left);
    this.right.setState(entry.right);
    this.nameInputs[0].value = entry.leftName;
    this.nameInputs[1].value = entry.rightName;
    this.syntax.value = SYNTAXES.some(([v]) => v === entry.syntax) ? entry.syntax : 'text';
    this.lastFocus = null;
    this.applyMode(false);
    this.updateStats(true);
  }

  /** Keeps the on-screen editors' state (undo history, selection) for when this scratch comes back. */
  stash() {
    if (!this.entry) return;
    this.syncFromMerge();
    this.entry.left = this.left.state;
    this.entry.right = this.right.state;
    this.destroyMerge();
    this.entry = null;
    this.id = null;
  }

  forget(id) {
    if (this.id === id) this.stash();
    this.docs.delete(id);
  }

  rename(oldId, newId) {
    if (this.id === oldId) this.id = newId;
    const entry = this.docs.get(oldId);
    if (entry) {
      this.docs.delete(oldId);
      this.docs.set(newId, entry);
    }
  }

  texts() {
    if (this.merge) return [this.merge.a.state.doc.toString(), this.merge.b.state.doc.toString()];
    return [this.left.state.doc.toString(), this.right.state.doc.toString()];
  }

  serialize() {
    return this.entry ? this.serializeEntry(this.entry) : '';
  }

  // ---- modes ----

  get mode() {
    return this.entry?.mode ?? 'edit';
  }

  setMode(mode) {
    if (!this.entry || this.entry.mode === mode) return;
    this.syncFromMerge();
    this.entry.mode = mode;
    this.applyMode(true);
  }

  toggleMode() {
    this.setMode(this.mode === 'diff' ? 'edit' : 'diff');
  }

  applyMode(focus) {
    const diff = this.mode === 'diff';
    this.root.dataset.mode = this.mode;
    this.editTab.classList.toggle('on', !diff);
    this.diffTab.classList.toggle('on', diff);
    if (diff) this.renderDiff();
    else {
      this.destroyMerge();
      this.left.requestMeasure();
      this.right.requestMeasure();
    }
    if (focus) this.activeView()?.focus();
  }

  renderDiff() {
    if (!this.entry) return;
    const [a, b] = this.texts();
    this.destroyMerge();
    this.merge = buildMerge(this.diffBox, {
      a,
      b,
      extensions: this.deps.mergeExtensions(this.entry.syntax),
      editable: true,
      onChange: () => {
        this.deps.onChange();
        this.updateStats();
      },
    });
    for (const v of [this.merge.a, this.merge.b]) this.trackFocus(v);
    this.lastFocus = null;
  }

  destroyMerge() {
    if (this.merge) {
      this.merge.destroy();
      this.merge = null;
    }
  }

  /** Copies edits made in the diff view back into the edit-view editors. */
  syncFromMerge() {
    if (!this.merge) return;
    const pairs = [[this.left, this.merge.a], [this.right, this.merge.b]];
    for (const [target, source] of pairs) {
      const text = source.state.doc.toString();
      if (text !== target.state.doc.toString()) {
        target.dispatch({ changes: { from: 0, to: target.state.doc.length, insert: text }, userEvent: 'input.diff' });
      }
    }
  }

  // ---- editing helpers ----

  /** The editor that commands (find, transforms, status) should target. */
  activeView() {
    if (!this.entry) return null;
    if (this.merge) return this.lastFocus === this.merge.a ? this.merge.a : this.merge.b;
    return this.lastFocus ?? this.left;
  }

  views() {
    return this.merge ? [this.left, this.right, this.merge.a, this.merge.b] : [this.left, this.right];
  }

  /** Re-applies settings; the diff view is rebuilt because its editors are recreated from scratch anyway. */
  reconfigure(effects) {
    for (const v of [this.left, this.right]) v.dispatch({ effects });
    if (this.merge) {
      this.syncFromMerge();
      this.renderDiff();
    }
  }

  setSyntax(syntax) {
    if (!this.entry) return;
    this.entry.syntax = syntax;
    for (const v of [this.left, this.right]) v.dispatch({ effects: this.deps.languageEffect(syntax) });
    if (this.merge) {
      this.syncFromMerge();
      this.renderDiff();
    }
    this.deps.onChange();
  }

  swap() {
    if (!this.entry) return;
    const [a, b] = this.texts();
    [this.entry.leftName, this.entry.rightName] = [this.entry.rightName, this.entry.leftName];
    this.nameInputs[0].value = this.entry.leftName;
    this.nameInputs[1].value = this.entry.rightName;
    const set = (v, text) => v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: text }, userEvent: 'input.swap' });
    this.destroyMerge();
    set(this.left, b);
    set(this.right, a);
    if (this.mode === 'diff') this.renderDiff();
    this.deps.onChange();
    this.updateStats(true);
  }

  /** Formats both sides with the given async formatter; returns the first error, if any. */
  async format(formatter) {
    if (!this.entry) return { ok: false, error: 'Nothing to format' };
    if (this.entry.syntax === 'text') return { ok: false, error: 'Choose a syntax (JSON, XML, …) to format both sides' };
    this.syncFromMerge();
    const views = [this.left, this.right];
    const results = [];
    for (const v of views) {
      const src = v.state.doc.toString();
      try {
        results.push({ v, src, out: src.trim() ? await formatter(this.entry.syntax, src) : src });
      } catch (e) {
        return { ok: false, error: `${v === this.left ? this.entry.leftName || 'Left' : this.entry.rightName || 'Right'}: ${e?.message || e}` };
      }
    }
    for (const { v, src, out } of results) {
      if (out !== src && v.state.doc.toString() === src) {
        v.dispatch({ changes: { from: 0, to: src.length, insert: out }, userEvent: 'format' });
      }
    }
    if (this.merge) this.renderDiff();
    this.updateStats(true);
    return { ok: true };
  }

  /** Selects a range given in serialized-file offsets (used by Find in Scratches). */
  reveal(from, to) {
    if (!this.entry) return;
    const e = this.entry;
    const head = (e.syntax && e.syntax !== 'text' ? `--- syntax: ${e.syntax}\n` : '').length + `--- left: ${e.leftName}\n`.length;
    const [a] = this.texts();
    const rightStart = head + a.length + 1 + `--- right: ${e.rightName}\n`.length;
    const onRight = from >= rightStart;
    const offset = onRight ? rightStart : head;
    const v = this.merge ? (onRight ? this.merge.b : this.merge.a) : (onRight ? this.right : this.left);
    const len = v.state.doc.length;
    const f = Math.max(0, Math.min(from - offset, len));
    const t = Math.max(f, Math.min(to - offset, len));
    v.dispatch({ selection: { anchor: f, head: t }, effects: EditorView.scrollIntoView(f, { y: 'center' }) });
    v.focus();
  }

  onSideChanged() {
    this.updateStats();
  }

  updateStats(now = false) {
    clearTimeout(this.statsTimer);
    const run = () => {
      if (!this.entry) return;
      const [a, b] = this.texts();
      renderStats(this.stats, diffStats(a, b, diffOptions.ignoreWhitespace));
    };
    if (now) run();
    else this.statsTimer = setTimeout(run, 200);
  }
}
