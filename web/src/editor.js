import {
  EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter,
  drawSelection, dropCursor, rectangularSelection, crosshairCursor, highlightSpecialChars, Decoration,
} from '@codemirror/view';
import { EditorState, EditorSelection, Compartment, Prec, StateEffect, StateField } from '@codemirror/state';
import {
  history, standardKeymap, historyKeymap, indentWithTab, undo, redo, selectAll,
  copyLineDown, deleteLine, moveLineUp, moveLineDown, toggleComment, toggleBlockComment,
  selectParentSyntax, selectLine, addCursorAbove, addCursorBelow, cursorMatchingBracket,
  simplifySelection, insertBlankLine,
} from '@codemirror/commands';
import {
  search, highlightSelectionMatches, openSearchPanel, findNext, findPrevious,
  selectNextOccurrence, selectSelectionMatches, gotoLine, searchKeymap,
} from '@codemirror/search';
import {
  syntaxHighlighting, defaultHighlightStyle, indentOnInput, bracketMatching, foldGutter,
  foldCode, unfoldCode, foldAll, unfoldAll, indentUnit,
} from '@codemirror/language';
import { closeBrackets, closeBracketsKeymap, autocompletion, completionKeymap, acceptCompletion } from '@codemirror/autocomplete';
import { completionSources } from './completions.js';
import { oneDark } from '@codemirror/theme-one-dark';
import { languages } from './languages.js';
import { formatSource, FormatError } from './format.js';
import { Preview } from './preview.js';
import { DiffPanel, DiffWorkspace, diffOptions } from './diff.js';
import { ResponsePanel, newRun, applyResult, finishRun, toneOf, formatElapsed } from './response.js';
import { setRunning, setChip, setChipHandler, setRunShortcut, runState } from './http.js';
import { storage } from './storage.js';
import { parseCSV, serializeCSV, detectDelimiter, rowsFromHTML, delimiterName } from './csv.js';
import { documentSymbols } from './symbols.js';
import { createFindPanel } from './findPanel.js';

const post = (msg) => window.webkit?.messageHandlers?.bridge?.postMessage(msg);
const languageSupport = (name) => {
  const support = languages[name]?.() ?? [];
  return [support, completionSources(name, support)];
};

// ---------- custom multi-cursor commands ----------

const unselectOccurrence = (view) => {
  const sel = view.state.selection;
  if (sel.ranges.length < 2) return false;
  const ranges = sel.ranges.filter((_, i) => i !== sel.mainIndex);
  view.dispatch({ selection: EditorSelection.create(ranges, ranges.length - 1), scrollIntoView: true });
  return true;
};

const addCursorsToLineEnds = (view) => {
  const { state } = view;
  const ranges = [];
  for (const r of state.selection.ranges) {
    if (r.empty) {
      ranges.push(r);
      continue;
    }
    const first = state.doc.lineAt(r.from).number;
    const last = state.doc.lineAt(r.to).number;
    for (let n = first; n <= last; n++) ranges.push(EditorSelection.cursor(state.doc.line(n).to));
  }
  view.dispatch({ selection: EditorSelection.create(ranges) });
  return true;
};

let expandStack = [];
const expandSelection = (view) => {
  const before = view.state.selection;
  if (!selectParentSyntax(view)) return false;
  expandStack.push(before);
  return true;
};
const shrinkSelection = (view) => {
  const prev = expandStack.pop();
  if (!prev) return false;
  view.dispatch({ selection: prev });
  return true;
};

const selectAllOccurrences = (view) => {
  if (view.state.selection.main.empty) selectNextOccurrence(view);
  return selectSelectionMatches(view);
};

// Commands that the native side can bind to shortcuts or trigger from menus.
const commands = {
  undo, redo, selectAll,
  addNextOccurrence: selectNextOccurrence,
  unselectOccurrence,
  selectAllOccurrences,
  addCursorAbove,
  addCursorBelow,
  addCursorsToLineEnds,
  singleCursor: simplifySelection,
  duplicateLine: copyLineDown,
  deleteLine,
  moveLineUp,
  moveLineDown,
  toggleLineComment: toggleComment,
  toggleBlockComment,
  expandSelection,
  shrinkSelection,
  selectLine,
  jumpToBracket: cursorMatchingBracket,
  startNewLine: insertBlankLine,
  find: openSearchPanel,
  findNext,
  findPrevious,
  gotoLine,
  toggleDiffMode: () => (isDiffDoc() ? (workspace.toggleMode(), true) : false),
  fold: foldCode,
  unfold: unfoldCode,
  foldAll,
  unfoldAll,
};

// ---------- editor setup ----------

const languageConf = new Compartment();
const themeConf = new Compartment();
const keymapConf = new Compartment();
const settingsConf = new Compartment();
const wrapConf = new Compartment();

const darkQuery = window.matchMedia('(prefers-color-scheme: dark)');
const themeFor = () => (darkQuery.matches ? oneDark : syntaxHighlighting(defaultHighlightStyle, { fallback: true }));

let settings = { fontSize: 13, fontFamily: 'Menlo', tabSize: 2, lineWrap: false, autoComplete: true };
let editorBindings = {};
let appBindings = {};
let current = { id: null, language: 'text' };
// Editor states of recently open documents (undo history, selection, scroll), least recently used first.
// Bounded so browsing many or large files doesn't keep all of them in memory.
const stateCache = new Map();
const STATE_CACHE_ENTRIES = 12;
const STATE_CACHE_CHARS = 4_000_000;
function cacheState(id, state) {
  stateCache.delete(id);
  stateCache.set(id, state);
  let chars = 0;
  for (const s of stateCache.values()) chars += s.doc.length;
  for (const [key, s] of stateCache) {
    if (stateCache.size <= STATE_CACHE_ENTRIES && chars <= STATE_CACHE_CHARS) break;
    stateCache.delete(key);
    chars -= s.doc.length;
  }
}

function settingsExtension() {
  return [
    EditorState.tabSize.of(settings.tabSize),
    indentUnit.of(' '.repeat(settings.tabSize)),
    autocompletion({ activateOnTyping: settings.autoComplete, activateOnTypingDelay: 80, maxRenderedOptions: 80, icons: true }),
    EditorView.theme({
      '&': { fontSize: settings.fontSize + 'px' },
      '.cm-content, .cm-gutters, .cm-tooltip': { fontFamily: `"${settings.fontFamily}", Menlo, monospace` },
    }),
  ];
}

// App-level shortcuts are also registered here so they work reliably while the editor has focus
// (e.g. ⇧⌘8, which menu key equivalents match inconsistently); they are forwarded to native.
// An action may have several shortcuts (a list); older native builds sent one string.
const keysOf = (value) => (Array.isArray(value) ? value : value ? [value] : []).filter(Boolean);
function userKeymapExtension() {
  const bindings = [];
  for (const [name, keys] of Object.entries(editorBindings)) {
    if (commands[name]) for (const key of keysOf(keys)) bindings.push({ key, run: commands[name] });
  }
  for (const [id, keys] of Object.entries(appBindings)) {
    for (const key of keysOf(keys)) bindings.push({ key, run: () => (post({ type: 'action', id }), true) });
  }
  return Prec.highest(keymap.of(bindings));
}

const isDiffDoc = () => current.language === 'diff';
/** The editor that commands, transforms and the status bar act on. */
const activeView = () => (isDiffDoc() ? workspace.activeView() ?? view : view);
const currentText = () => (isDiffDoc() ? workspace.serialize() : view.state.doc.toString());

let pendingChange = null;
function flush() {
  if (pendingChange) {
    clearTimeout(pendingChange.timer);
    post({ type: 'change', id: pendingChange.id, text: currentText() });
    pendingChange = null;
  }
}

function scheduleSave() {
  if (!current.id) return;
  if (pendingChange) clearTimeout(pendingChange.timer);
  // Each save sends the whole text to native, so big documents wait for a longer pause.
  const length = view.state.doc.length;
  const delay = length < 200_000 ? 250 : length < 2_000_000 ? 800 : 1500;
  pendingChange = { id: current.id, timer: setTimeout(flush, delay) };
}

let statusFrame = 0;
function postStatus() {
  cancelAnimationFrame(statusFrame);
  statusFrame = requestAnimationFrame(() => {
    const { state } = activeView();
    const main = state.selection.main;
    const line = state.doc.lineAt(main.head);
    const selected = state.selection.ranges.reduce((n, r) => n + (r.to - r.from), 0);
    post({
      type: 'status',
      line: line.number,
      column: main.head - line.from + 1,
      cursors: state.selection.ranges.length,
      selected,
      length: state.doc.length,
    });
  });
}

const listener = EditorView.updateListener.of((u) => {
  if (u.docChanged && current.id) {
    scheduleSave();
    if (isDiffDoc()) workspace.onSideChanged();
    else {
      const pasted = u.transactions.some((t) => t.isUserEvent('input.paste'));
      if (pasted && u.startState.doc.length === 0) post({ type: 'pasteIntoEmpty', id: current.id });
      // Typing can turn a YAML/JSON file into an OpenAPI spec (or stop it being one), which shows or hides the preview.
      const kind = previewKind(u.state.doc);
      if (u.changes.touchesRange(0, 20_000) && kind !== previewKind(u.startState.doc)) applyPreviewMode();
      else if (previewMode !== 'off' && kind) preview.scheduleRender(kind, u.state.doc);
    }
  }
  if (u.docChanged) expandStack = [];
  if (u.docChanged || u.selectionSet) postStatus();
});

// Pasting a curl command into an HTTP scratch hands it to native for conversion into a request.
const curlPaste = EditorView.domEventHandlers({
  paste(event, view) {
    if (current.language !== 'http') return false;
    const text = event.clipboardData?.getData('text/plain') ?? '';
    if (!/^\s*curl(\.exe)?\s/i.test(text)) return false;
    event.preventDefault();
    const { from, to } = view.state.selection.main;
    const before = view.state.sliceDoc(0, from).trimEnd();
    const after = view.state.sliceDoc(to).trimStart();
    const lastLine = before.slice(before.lastIndexOf('\n') + 1);
    post({
      type: 'pasteCurl',
      text,
      before: before.length > 0 && !lastLine.startsWith('###'),
      after: after.length > 0 && !after.startsWith('###'),
    });
    return true;
  },
});

const isTable = (language) => language === 'csv' || language === 'tsv';

// Pasting rows into a CSV/TSV scratch converts them to the file's delimiter: cells copied from a
// spreadsheet (tabs) become CSV, semicolon exports become commas, HTML tables become rows.
const tablePaste = EditorView.domEventHandlers({
  paste(event, view) {
    if (!isTable(current.language)) return false;
    const plain = event.clipboardData?.getData('text/plain') ?? '';
    const html = event.clipboardData?.getData('text/html') ?? '';
    const { doc } = view.state;
    const target = current.language === 'tsv' ? '\t'
      : (doc.length > 0 ? detectDelimiter(doc.sliceString(0, Math.min(doc.length, 8000))) : null) ?? ',';
    const source = detectDelimiter(plain);
    let rows = null;
    if (source && source !== target) rows = parseCSV(plain, source);
    else if (!source && /<table[\s>]/i.test(html)) rows = rowsFromHTML(html);
    if (!rows?.length) return false;
    event.preventDefault();
    let out = serializeCSV(rows, target);
    const { from } = view.state.selection.main;
    const atLineStart = from === doc.lineAt(from).from;
    if (atLineStart && from < doc.length && !out.endsWith('\n')) out += '\n';
    view.dispatch({ ...view.state.replaceSelection(out), userEvent: 'input.paste', scrollIntoView: true });
    post({
      type: 'message',
      text: `Pasted ${rows.length} row${rows.length === 1 ? '' : 's'}`
        + (source ? ` (${delimiterName(source)}-separated → ${delimiterName(target)}-separated)` : ' from a table'),
    });
    return true;
  },
});

// Go to Symbol: the line of the highlighted symbol is marked while the picker is open.
const setSymbolPeek = StateEffect.define();
const symbolPeekLine = Decoration.line({ class: 'cm-symbolPeek' });
const symbolPeekField = StateField.define({
  create: () => Decoration.none,
  update(deco, tr) {
    for (const e of tr.effects) {
      if (e.is(setSymbolPeek)) {
        return e.value == null ? Decoration.none : Decoration.set([symbolPeekLine.range(tr.state.doc.lineAt(e.value).from)]);
      }
    }
    return tr.docChanged ? Decoration.none : deco;
  },
  provide: (f) => EditorView.decorations.from(f),
});
let symbolPeek = null;

function extensions(language) {
  return [
    curlPaste,
    symbolPeekField,
    tablePaste,
    lineNumbers(),
    highlightActiveLineGutter(),
    highlightSpecialChars(),
    history(),
    foldGutter(),
    drawSelection(),
    dropCursor(),
    EditorState.allowMultipleSelections.of(true),
    indentOnInput(),
    bracketMatching(),
    closeBrackets(),
    rectangularSelection(),
    crosshairCursor(),
    highlightActiveLine(),
    highlightSelectionMatches(),
    search({ top: true, createPanel: createFindPanel }),
    keymapConf.of(userKeymapExtension()),
    keymap.of([
      ...closeBracketsKeymap,
      ...standardKeymap,
      ...historyKeymap,
      ...searchKeymap.filter((b) => b.key === 'Escape'),
      ...completionKeymap,
      { key: 'Tab', run: acceptCompletion },
      indentWithTab,
    ]),
    languageConf.of(languageSupport(language)),
    themeConf.of(themeFor()),
    settingsConf.of(settingsExtension()),
    wrapConf.of(settings.lineWrap ? EditorView.lineWrapping : []),
    listener,
    EditorView.theme({
      '&': { height: '100%' },
      '.cm-scroller': { overflow: 'auto' },
      '&.cm-focused': { outline: 'none' },
      '.cm-content': { padding: '12px 0 24px 0' },
      '.cm-symbolPeek': { backgroundColor: 'rgba(255, 196, 0, 0.18)', boxShadow: 'inset 3px 0 0 rgba(255, 170, 0, 0.9)' },
    }),
  ];
}

const view = new EditorView({
  parent: document.getElementById('editor'),
  state: EditorState.create({ doc: '', extensions: extensions('text') }),
});

// Diff scratches: two named sides edited side by side, plus a diff view of them.
function mergeExtensions(syntax) {
  return [
    lineNumbers(),
    highlightSpecialChars(),
    foldGutter(),
    history(),
    drawSelection(),
    highlightSelectionMatches(),
    search({ top: true, createPanel: createFindPanel }),
    keymapConf.of(userKeymapExtension()),
    keymap.of([...standardKeymap, ...historyKeymap, ...searchKeymap.filter((b) => b.key === 'Escape'), indentWithTab]),
    themeConf.of(themeFor()),
    settingsConf.of(settingsExtension()),
    languageConf.of(languageSupport(syntax)),
    EditorView.updateListener.of((u) => { if (u.selectionSet || u.docChanged) postStatus(); }),
    EditorView.theme({
      '&.cm-focused': { outline: 'none' },
      '.cm-content': { padding: '12px 0 24px 0' },
    }),
  ];
}

const workspace = new DiffWorkspace(document.getElementById('diffdoc'), {
  sideExtensions: (syntax) => extensions(syntax),
  mergeExtensions,
  languageEffect: (syntax) => languageConf.reconfigure(languageSupport(syntax)),
  onChange: scheduleSave,
  onFocus: postStatus,
});

// Diff scratches follow the diff view's Wrap toggle; other scratches follow the Soft Wrap setting.
const wrapEffect = () => wrapConf.reconfigure((isDiffDoc() ? diffOptions.wrap : settings.lineWrap) ? EditorView.lineWrapping : []);

function commonEffects() {
  return [
    keymapConf.reconfigure(userKeymapExtension()),
    themeConf.reconfigure(themeFor()),
    settingsConf.reconfigure(settingsExtension()),
    wrapEffect(),
  ];
}

diffOptions.subscribe(() => {
  if (isDiffDoc()) for (const v of [workspace.left, workspace.right]) v.dispatch({ effects: wrapEffect() });
});

// Re-applies the current compartments to a cached state that may have been built with older settings.
function refresh() {
  if (isDiffDoc()) {
    workspace.reconfigure(commonEffects());
    return;
  }
  view.dispatch({ effects: [...commonEffects(), languageConf.reconfigure(languageSupport(current.language))] });
}

function applyDocKind() {
  document.body.dataset.doc = isDiffDoc() ? 'diff' : 'code';
}

darkQuery.addEventListener('change', () => {
  view.dispatch({ effects: themeConf.reconfigure(themeFor()) });
  workspace.reconfigure([themeConf.reconfigure(themeFor())]);
  responsePanel.refreshTheme(themeFor());
});

// ---------- preview & diff ----------

const preview = new Preview(document.getElementById('preview'));
let previewMode = 'off'; // 'off' | 'split' | 'full'

const OPENAPI_YAML = /^["']?(?:openapi|swagger)["']?\s*:\s*["']?\d/m;
const OPENAPI_JSON = /"(?:openapi|swagger)"\s*:\s*"\d/;

/** What the preview shows for the open document, or null when it has none. */
function previewKind(doc = view.state.doc) {
  const language = current.language;
  if (['markdown', 'html', 'csv', 'tsv'].includes(language)) return language;
  if (language === 'openapi') return 'openapi';
  if (language === 'yaml' || language === 'json') {
    const head = doc.sliceString(0, 20_000);
    if ((language === 'yaml' ? OPENAPI_YAML : OPENAPI_JSON).test(head)) return 'openapi';
  }
  return null;
}

function applyPreviewMode() {
  const kind = isDiffDoc() ? null : previewKind();
  const mode = kind ? previewMode : 'off';
  document.body.dataset.preview = mode;
  if (mode !== 'off') preview.render(kind, view.state.doc);
  if (mode !== 'full') view.requestMeasure();
  post({ type: 'previewMode', mode, available: kind !== null, kind });
}

view.scrollDOM.addEventListener('scroll', () => {
  if (previewMode !== 'split') return;
  const el = view.scrollDOM;
  const max = el.scrollHeight - el.clientHeight;
  preview.syncScroll(max > 0 ? el.scrollTop / max : 0);
});

const diff = new DiffPanel(document.getElementById('diff'), () => {
  post({ type: 'diffClosed' });
  view.focus();
});

// ---------- HTTP response panel ----------

const responseRuns = new Map(); // scratch id -> run
const responseHidden = new Set(); // scratch ids whose panel the user closed
const responsePanel = new ResponsePanel(document.getElementById('response'), {
  languageSupport,
  baseExtensions: () => settingsExtension(),
  onClose: () => {
    if (current.id) responseHidden.add(current.id);
    applyResponseMode();
    view.focus();
  },
});
responsePanel.refreshTheme(themeFor());

function applyResponseMode() {
  const open = current.language === 'http' && responseRuns.has(current.id) && !responseHidden.has(current.id);
  document.body.dataset.response = open ? 'open' : 'closed';
  if (open) responsePanel.restore(responseRuns.get(current.id));
  view.requestMeasure();
}

function showResponsePanel() {
  responseHidden.delete(current.id);
  applyResponseMode();
}

/** Applies effects to a scratch's editor state, whether it is on screen or cached. */
function dispatchTo(id, effects) {
  if (id === current.id) view.dispatch({ effects });
  else {
    const cached = stateCache.get(id);
    if (cached) stateCache.set(id, cached.update({ effects }).state);
  }
}

function runningLines(run) {
  return run.entries.filter((e) => e.pending).map((e) => e.request.line);
}

setChipHandler((pos) => {
  if (!responseRuns.has(current.id)) return;
  showResponsePanel();
  responsePanel.selectLine(pos);
});

// Drag the divider between editor and response to resize; the width is remembered.
(() => {
  const main = document.getElementById('main');
  const handle = document.getElementById('response-resizer');
  const saved = Number(storage.get('responseWidth'));
  if (saved) main.style.setProperty('--response-width', `${saved}px`);
  handle.addEventListener('mousedown', (event) => {
    event.preventDefault();
    handle.classList.add('dragging');
    document.body.classList.add('resizing');
    const move = (e) => {
      const rect = main.getBoundingClientRect();
      const width = Math.min(Math.max(rect.right - e.clientX, 300), rect.width - 260);
      main.style.setProperty('--response-width', `${width}px`);
      storage.set('responseWidth', String(Math.round(width)));
    };
    const up = () => {
      handle.classList.remove('dragging');
      document.body.classList.remove('resizing');
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      view.requestMeasure();
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  });
  handle.addEventListener('dblclick', () => {
    main.style.removeProperty('--response-width');
    storage.remove('responseWidth');
  });
})();

const keyLabel = (key) => key
  ?.split('-')
  .map((part) => ({ Ctrl: '⌃', Alt: '⌥', Shift: '⇧', Cmd: '⌘', Mod: '⌘', Enter: '↩' })[part] ?? part.toUpperCase())
  .join('');

// ---------- formatting ----------

function positionOf(state, pos) {
  const line = state.doc.lineAt(Math.min(pos, state.doc.length));
  return { line: line.number, column: pos - line.from + 1 };
}

function jumpTo(pos) {
  const clamped = Math.min(pos, view.state.doc.length);
  view.dispatch({ selection: EditorSelection.cursor(clamped), scrollIntoView: true });
  view.focus();
  return positionOf(view.state, clamped);
}

async function format(compact = false) {
  if (isDiffDoc()) {
    return workspace.format(async (syntax, src) => {
      try {
        return await formatSource(syntax, src, { tabSize: settings.tabSize, compact });
      } catch (e) {
        throw new Error(e instanceof FormatError && e.line ? `${e.message} at line ${e.line}` : e?.message || String(e));
      }
    });
  }
  const { state } = view;
  const src = state.doc.toString();
  const language = current.language;
  let out;
  try {
    out = await formatSource(language, src, { tabSize: settings.tabSize, compact });
  } catch (e) {
    if (!(e instanceof FormatError)) return { ok: false, error: String(e?.message || e) };
    let p = null;
    if (e.offset != null) p = jumpTo(e.offset);
    else if (e.line && e.line <= state.doc.lines) {
      const line = state.doc.line(e.line);
      p = jumpTo(Math.min(line.from + Math.max((e.column ?? 1) - 1, 0), line.to));
    }
    return { ok: false, error: p ? `${e.message} at line ${p.line}, column ${p.column}` : e.message };
  }
  // The user may have switched scratches while an async format was running.
  if (current.language !== language || view.state.doc.toString() !== src) {
    return { ok: false, error: 'Document changed while formatting' };
  }
  if (out !== src) {
    const head = Math.min(state.selection.main.head, out.length);
    view.dispatch({
      changes: { from: 0, to: state.doc.length, insert: out },
      selection: EditorSelection.cursor(head),
      userEvent: 'format',
      scrollIntoView: true,
    });
  }
  return { ok: true };
}

// ---------- bridge API used by Swift ----------

window.ScratchEditor = {
  load(id, text, language) {
    flush();
    diff.close();
    if (current.id && !isDiffDoc()) cacheState(current.id, view.state);
    workspace.stash();
    current = { id, language };
    expandStack = [];
    applyDocKind();
    if (language === 'diff') {
      workspace.load(id, text);
      refresh();
    } else {
      const cached = stateCache.get(id);
      if (cached && cached.doc.length === text.length && cached.doc.toString() === text) {
        view.setState(cached);
        refresh();
      } else {
        view.setState(EditorState.create({ doc: text, extensions: extensions(language) }));
      }
    }
    applyPreviewMode();
    applyResponseMode();
    postStatus();
    if (previewMode !== 'full' || isDiffDoc()) activeView().focus();
  },
  forget(id) {
    stateCache.delete(id);
    workspace.forget(id);
    responseRuns.delete(id);
    responseHidden.delete(id);
  },
  rename(oldId, newId) {
    if (current.id === oldId) current.id = newId;
    if (pendingChange?.id === oldId) pendingChange.id = newId;
    workspace.rename(oldId, newId);
    const cached = stateCache.get(oldId);
    if (cached) {
      stateCache.delete(oldId);
      cacheState(newId, cached);
    }
    if (responseRuns.has(oldId)) {
      responseRuns.set(newId, responseRuns.get(oldId));
      responseRuns.delete(oldId);
    }
    if (responseHidden.delete(oldId)) responseHidden.add(newId);
  },
  setLanguage(language) {
    const wasDiff = isDiffDoc();
    if (wasDiff && language !== 'diff') {
      // Leaving the diff type keeps the file's text as is; switching back restores both sides.
      const text = workspace.serialize();
      workspace.forget(current.id);
      current.language = language;
      view.setState(EditorState.create({ doc: text, extensions: extensions(language) }));
    } else if (!wasDiff && language === 'diff') {
      const text = view.state.doc.toString();
      stateCache.delete(current.id);
      current.language = language;
      workspace.load(current.id, text);
      refresh();
      scheduleSave();
    } else {
      current.language = language;
      if (language !== 'diff') view.dispatch({ effects: languageConf.reconfigure(languageSupport(language)) });
    }
    applyDocKind();
    applyPreviewMode();
    applyResponseMode();
    postStatus();
    activeView().focus();
  },
  setSettings(s) {
    settings = { ...settings, ...s };
    refresh();
    responsePanel.invalidate();
  },
  // editor: { command: key }, app: { actionId: key } — keys in CodeMirror notation.
  setKeymap(editor, app) {
    editorBindings = editor ?? {};
    appBindings = app ?? {};
    setRunShortcut(keyLabel(keysOf(appBindings.run)[0]));
    view.dispatch({ effects: keymapConf.reconfigure(userKeymapExtension()) });
    for (const v of workspace.views()) v.dispatch({ effects: keymapConf.reconfigure(userKeymapExtension()) });
  },
  exec(name) {
    const cmd = commands[name];
    if (!cmd) return false;
    const target = activeView();
    target.focus();
    return cmd(target);
  },
  format() {
    return format(false);
  },
  compact() {
    return format(true);
  },
  getText() {
    return currentText();
  },
  getTextAndCursor() {
    return { text: currentText(), cursor: isDiffDoc() ? 0 : view.state.selection.main.head };
  },
  getSelectionText() {
    const { state } = activeView();
    return state.sliceDoc(state.selection.main.from, state.selection.main.to);
  },
  /** Non-empty selections, or the whole document when nothing is selected. Offsets are UTF-16. */
  getSelections() {
    const { state } = activeView();
    const ranges = state.selection.ranges.filter((r) => !r.empty);
    if (ranges.length === 0) return { whole: true, ranges: [{ from: 0, to: state.doc.length, text: state.doc.toString() }] };
    return { whole: false, ranges: ranges.map((r) => ({ from: r.from, to: r.to, text: state.sliceDoc(r.from, r.to) })) };
  },
  /** Replaces ranges (from getSelections) in one undoable step and selects the results. */
  replaceRanges(replacements, selectResult = true) {
    const view = activeView();
    const sorted = [...replacements].sort((a, b) => a.from - b.from);
    const changes = view.state.changes(sorted.map((r) => ({ from: r.from, to: r.to, insert: r.text })));
    let shift = 0;
    const ranges = sorted.map((r) => {
      const from = r.from + shift;
      shift += r.text.length - (r.to - r.from);
      return EditorSelection.range(from, from + r.text.length);
    });
    const whole = sorted.length === 1 && sorted[0].from === 0 && sorted[0].to === view.state.doc.length;
    view.dispatch({
      changes,
      selection: selectResult && !whole ? EditorSelection.create(ranges) : undefined,
      userEvent: 'input.transform',
      scrollIntoView: true,
    });
    view.focus();
  },
  /** Inserts text at every caret (replacing any selection). */
  insertAtCursors(text) {
    const view = activeView();
    view.dispatch(view.state.replaceSelection(text));
    view.focus();
  },
  // Offsets are UTF-16 indices, the same unit NSString uses on the native side.
  reveal(from, to) {
    if (isDiffDoc()) {
      workspace.reveal(from, to);
      return;
    }
    const len = view.state.doc.length;
    view.dispatch({
      selection: EditorSelection.single(Math.min(from, len), Math.min(to, len)),
      effects: EditorView.scrollIntoView(Math.min(from, len), { y: 'center' }),
    });
    view.focus();
  },
  setPreview(mode) {
    previewMode = mode;
    applyPreviewMode();
    if (mode !== 'full' || isDiffDoc()) activeView().focus();
  },
  showDiff(aName, aText, bName, bText, language) {
    flush();
    diff.open({ aName, aText, bName, bText, extensions: [themeFor(), settingsExtension(), languageSupport(language)] });
  },
  closeDiff() {
    diff.close();
  },
  // ---- HTTP runs; ids may belong to a scratch that is no longer on screen ----
  httpStarted(id, requests) {
    const run = newRun(requests);
    responseRuns.set(id, run);
    responseHidden.delete(id);
    dispatchTo(id, [setRunning.of(runningLines(run))]);
    if (id === current.id) applyResponseMode();
  },
  httpResult(id, index, result) {
    const run = responseRuns.get(id);
    if (!run) return;
    applyResult(run, index, result);
    const entry = run.entries[index];
    const label = result.error ? (result.cancelled ? 'Cancelled' : 'Failed') : `${result.status} ${result.reason}`;
    dispatchTo(id, [
      setRunning.of(runningLines(run)),
      setChip.of({ pos: entry.request.line, label, detail: result.error ? '' : formatElapsed(result.elapsedMs), tone: toneOf(result) }),
    ]);
    if (id === current.id && document.body.dataset.response === 'open') responsePanel.restore(run);
  },
  httpFinished(id, cancelled) {
    const run = responseRuns.get(id);
    if (!run) return;
    const pending = run.entries.filter((e) => e.pending);
    finishRun(run, cancelled);
    const effects = [setRunning.of([])];
    for (const entry of pending) {
      effects.push(setChip.of({ pos: entry.request.line, label: cancelled ? 'Cancelled' : 'Failed', detail: '', tone: 'error' }));
    }
    dispatchTo(id, effects);
    if (id === current.id && document.body.dataset.response === 'open') responsePanel.restore(run);
  },
  flush,
  /** A standalone HTML page of the Markdown preview for the native exports; `mode` is 'print' or 'html'. */
  previewDocument(title, mode) {
    if (current.language !== 'markdown') return null;
    return preview.printableDocument(view.state.doc.toString(), title, mode);
  },
  setSpecViewer(viewer) {
    preview.setSpecViewer(viewer);
  },
  /** Zooms the Markdown preview when it is what the user is looking at; false leaves ⌘+/⌘− to the editor font. */
  zoomPreview(step) {
    const mode = document.body.dataset.preview;
    if (current.language !== 'markdown' || isDiffDoc() || !mode || mode === 'off') return false;
    if (mode === 'split' && (!preview.active || activeView().hasFocus)) return false;
    preview.zoomBy(step);
    return true;
  },
  copyRichText() {
    if (current.language !== 'markdown') return false;
    preview.copyRich(view.state.doc.toString());
    return true;
  },
  focus() {
    activeView().focus();
  },
  // ---- Go to Symbol; offsets are UTF-16 like everything else here ----
  /** The outline of the document (or the focused side of a diff), remembering the scroll position to go back to. */
  symbols() {
    const target = activeView();
    const language = isDiffDoc() ? workspace.syntax.value : current.language;
    const { symbols, truncated } = documentSymbols(target.state, language);
    symbolPeek = { view: target, top: target.scrollDOM.scrollTop, left: target.scrollDOM.scrollLeft };
    const { doc } = target.state;
    return {
      truncated,
      cursor: target.state.selection.main.head,
      symbols: symbols.map((s) => [s.name, s.kind, s.from, s.to, s.end, s.depth, doc.lineAt(s.from).number, s.container, s.detail]),
    };
  },
  peekSymbol(from) {
    const target = symbolPeek?.view ?? activeView();
    const pos = Math.min(from, target.state.doc.length);
    target.dispatch({ effects: [setSymbolPeek.of(pos), EditorView.scrollIntoView(pos, { y: 'center' })] });
  },
  /** Jumps to (and selects) the chosen symbol, or with no range puts the view back where it was. */
  endSymbolPeek(from, to) {
    const target = symbolPeek?.view ?? activeView();
    const saved = symbolPeek;
    symbolPeek = null;
    target.dispatch({ effects: setSymbolPeek.of(null) });
    if (from == null) {
      if (saved) {
        target.scrollDOM.scrollTop = saved.top;
        target.scrollDOM.scrollLeft = saved.left;
      }
    } else {
      const len = target.state.doc.length;
      target.dispatch({
        selection: EditorSelection.single(Math.min(from, len), Math.min(to, len)),
        effects: EditorView.scrollIntoView(Math.min(from, len), { y: 'center' }),
        userEvent: 'select.symbol',
      });
    }
    target.focus();
  },
};

post({ type: 'ready' });
