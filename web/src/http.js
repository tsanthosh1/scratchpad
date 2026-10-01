import { LanguageSupport, StreamLanguage } from '@codemirror/language';
import { gutter, GutterMarker, EditorView, Decoration, WidgetType } from '@codemirror/view';
import { StateField, StateEffect, RangeSet } from '@codemirror/state';

const post = (msg) => window.webkit?.messageHandlers?.bridge?.postMessage(msg);

const METHOD = /^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|TRACE|CONNECT)\b/;
export const REQUEST_LINE = /^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|TRACE|CONNECT)\s+\S/;

// ---------- syntax ----------

// Sections of a request block: 'start' (comments, @variables, request line), 'headers', 'body'.
const httpMode = {
  name: 'http',
  startState: () => ({ section: 'start', inRequestLine: false, param: false }),
  copyState: (s) => ({ ...s }),
  blankLine(state) {
    if (state.inRequestLine || state.section === 'headers') {
      state.inRequestLine = false;
      state.section = 'body';
    }
  },
  token(stream, state) {
    if (stream.sol()) {
      if (state.inRequestLine) {
        state.inRequestLine = false;
        state.section = 'headers';
      }
      if (stream.match(/^###.*/)) {
        state.section = 'start';
        return 'heading';
      }
    }

    if (state.section === 'start') {
      if (stream.sol()) {
        if (stream.match(/^\s*(#|\/\/).*/)) return 'comment';
        if (stream.match(/^@[\w.-]+/)) return 'propertyName';
        if (stream.match(METHOD)) {
          state.inRequestLine = true;
          return 'keyword';
        }
        if (stream.match(/^\S/, false)) state.inRequestLine = true;
      }
      if (stream.match(/^\{\{[^{}]*\}\}/)) return 'variableName';
      if (stream.match(/^HTTP\/[\d.]+/)) return 'meta';
      if (stream.match(/^\s+/)) return null;
      if (state.inRequestLine) {
        stream.match(/^[^\s{]+/) || stream.next();
        return 'string';
      }
      stream.next();
      return null;
    }

    if (stream.match(/^\{\{[^{}]*\}\}/)) return 'variableName';

    if (state.section === 'headers') {
      // Query parameter continuation lines: `    ?name=value` / `    &name=value`.
      if (stream.sol()) state.param = false;
      if (stream.sol() && stream.match(/^\s+[?&]/)) {
        state.param = true;
        return 'operator';
      }
      if (state.param) {
        if (stream.match(/^[^=&\s{]+(?==)/)) return 'propertyName';
        if (stream.match('=')) return 'operator';
        stream.match(/^[^&\s{]+/) || stream.next();
        return 'string';
      }
      if (stream.sol() && stream.match(/^\s*(#|\/\/).*/)) return 'comment';
      if (stream.sol() && stream.match(/^[\w-]+(?=\s*:)/)) return 'propertyName';
      if (stream.match(/^:\s*/)) return 'punctuation';
      stream.match(/^[^{]+/) || stream.next();
      return 'string';
    }

    // body
    if (stream.sol() && stream.match(/^<\s+\S.*/)) return 'meta';
    if (stream.match(/^"(?:[^"\\]|\\.)*"(?=\s*:)/)) return 'propertyName';
    if (stream.match(/^"(?:[^"\\]|\\.)*"?/)) return 'string';
    if (stream.match(/^-?\d+(\.\d+)?([eE][+-]?\d+)?/)) return 'number';
    if (stream.match(/^(true|false|null)\b/)) return 'atom';
    stream.next();
    return null;
  },
  languageData: { commentTokens: { line: '#' } },
};

// ---------- run state: running lines + status chips ----------

/** Lines (by start offset) whose requests are in flight. */
export const setRunning = StateEffect.define();
/** { pos, status, label, detail, tone } — tone is ok | redirect | warn | error. */
export const setChip = StateEffect.define();
export const clearChips = StateEffect.define();

class ChipWidget extends WidgetType {
  constructor(chip) {
    super();
    this.chip = chip;
  }
  eq(other) {
    return other.chip.label === this.chip.label && other.chip.detail === this.chip.detail
      && other.chip.tone === this.chip.tone;
  }
  toDOM() {
    const el = document.createElement('button');
    el.className = `cm-http-chip tone-${this.chip.tone}`;
    el.type = 'button';
    el.title = 'Show response';
    el.dataset.pos = String(this.chip.pos);
    const dot = document.createElement('span');
    dot.className = 'dot';
    const label = document.createElement('span');
    label.className = 'label';
    label.textContent = this.chip.label;
    el.append(dot, label);
    if (this.chip.detail) {
      const detail = document.createElement('span');
      detail.className = 'detail';
      detail.textContent = this.chip.detail;
      el.append(detail);
    }
    return el;
  }
  ignoreEvent() {
    return false;
  }
}

const mapPositions = (list, changes) => list.map((p) => changes.mapPos(p, -1));

export const runState = StateField.define({
  create: () => ({ running: [], chips: Decoration.none }),
  update(value, tr) {
    let { running, chips } = value;
    if (tr.docChanged) {
      running = mapPositions(running, tr.changes);
      chips = chips.map(tr.changes);
    }
    for (const e of tr.effects) {
      if (e.is(setRunning)) running = e.value;
      else if (e.is(clearChips)) chips = Decoration.none;
      else if (e.is(setChip)) {
        const doc = tr.state.doc;
        if (e.value.pos > doc.length) continue;
        const line = doc.lineAt(e.value.pos);
        chips = chips.update({
          filter: (from) => doc.lineAt(from).number !== line.number,
          add: [Decoration.widget({ widget: new ChipWidget({ ...e.value, pos: line.from }), side: 1 }).range(line.to)],
        });
      }
    }
    return { running, chips };
  },
  provide: (f) => EditorView.decorations.from(f, (v) => v.chips),
});

// ---------- gutter ----------

class RunMarker extends GutterMarker {
  constructor(running) {
    super();
    this.running = running;
  }
  eq(other) {
    return other.running === this.running;
  }
  toDOM() {
    const el = document.createElement('div');
    el.className = this.running ? 'cm-http-run running' : 'cm-http-run';
    el.title = this.running ? 'Running… (click to run again)' : `Run request${runShortcut ? ` (${runShortcut})` : ''}`;
    el.innerHTML = this.running
      ? '<span class="spinner"></span>'
      : '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M5 3.2v9.6a.6.6 0 0 0 .9.5l7.4-4.8a.6.6 0 0 0 0-1L5.9 2.7a.6.6 0 0 0-.9.5z"/></svg>';
    return el;
  }
}
const idleMarker = new RunMarker(false);
const runningMarker = new RunMarker(true);

let runShortcut = '';
/** Human-readable shortcut shown in the run button tooltip, e.g. "⌃R". */
export function setRunShortcut(key) {
  runShortcut = key ?? '';
}

const runGutter = gutter({
  class: 'cm-http-gutter',
  lineMarker(view, block) {
    const line = view.state.doc.lineAt(block.from);
    if (!REQUEST_LINE.test(line.text)) return null;
    return view.state.field(runState).running.includes(line.from) ? runningMarker : idleMarker;
  },
  lineMarkerChange: (update) => update.docChanged || update.transactions.some((t) => t.effects.some((e) => e.is(setRunning))),
  initialSpacer: () => idleMarker,
  domEventHandlers: {
    mousedown(view, block, event) {
      const line = view.state.doc.lineAt(block.from);
      if (!REQUEST_LINE.test(line.text) || !event.target.closest?.('.cm-http-run')) return false;
      event.preventDefault();
      post({ type: 'runRequest', offset: line.from });
      return true;
    },
  },
});

const chipClicks = EditorView.domEventHandlers({
  mousedown(event, view) {
    const chip = event.target.closest?.('.cm-http-chip');
    if (!chip) return false;
    event.preventDefault();
    onChipClick?.(Number(chip.dataset.pos));
    return true;
  },
});

let onChipClick = null;
export function setChipHandler(fn) {
  onChipClick = fn;
}

const theme = EditorView.baseTheme({
  '.cm-http-gutter': { minWidth: '22px' },
  '.cm-http-gutter .cm-gutterElement': { display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '0 2px' },
  '.cm-http-run': {
    width: '18px', height: '18px', maxHeight: '100%', borderRadius: '5px', display: 'flex', alignItems: 'center',
    justifyContent: 'center', cursor: 'pointer', color: '#2da44e', transition: 'background-color .12s, transform .08s, color .12s',
  },
  '.cm-http-run svg': { width: '12px', height: '12px', fill: 'currentColor' },
  '.cm-http-run:hover': { backgroundColor: 'rgba(45, 164, 78, .16)', color: '#1f883d' },
  '.cm-http-run:active': { transform: 'scale(.86)', backgroundColor: 'rgba(45, 164, 78, .28)' },
  '.cm-http-run .spinner': {
    width: '10px', height: '10px', borderRadius: '50%', border: '2px solid rgba(45, 164, 78, .25)',
    borderTopColor: '#2da44e', animation: 'cm-http-spin .7s linear infinite',
  },
  '&dark .cm-http-run': { color: '#56d364' },
  '&dark .cm-http-run:hover': { backgroundColor: 'rgba(86, 211, 100, .16)', color: '#7ee787' },
  '.cm-http-chip': {
    display: 'inline-flex', alignItems: 'center', gap: '5px', marginLeft: '12px', padding: '0 7px', height: '15px',
    verticalAlign: 'top', marginTop: '1px', borderRadius: '8px', border: '1px solid transparent', cursor: 'pointer',
    font: '10.5px/13px -apple-system, BlinkMacSystemFont, sans-serif', fontWeight: '500', boxSizing: 'border-box',
    transition: 'filter .12s, transform .08s, box-shadow .12s', userSelect: 'none',
  },
  '.cm-http-chip:hover': { filter: 'brightness(1.08)', boxShadow: '0 1px 3px rgba(0,0,0,.18)' },
  '.cm-http-chip:active': { transform: 'scale(.95)' },
  '.cm-http-chip .dot': { width: '6px', height: '6px', borderRadius: '50%', backgroundColor: 'currentColor' },
  '.cm-http-chip .detail': { opacity: '.75', fontWeight: '400' },
  '.cm-http-chip.tone-ok': { color: '#1a7f37', backgroundColor: 'rgba(45, 164, 78, .12)', borderColor: 'rgba(45, 164, 78, .3)' },
  '.cm-http-chip.tone-redirect': { color: '#0969da', backgroundColor: 'rgba(9, 105, 218, .1)', borderColor: 'rgba(9, 105, 218, .3)' },
  '.cm-http-chip.tone-warn': { color: '#9a6700', backgroundColor: 'rgba(212, 167, 44, .14)', borderColor: 'rgba(212, 167, 44, .4)' },
  '.cm-http-chip.tone-error': { color: '#cf222e', backgroundColor: 'rgba(207, 34, 46, .1)', borderColor: 'rgba(207, 34, 46, .3)' },
  '&dark .cm-http-chip.tone-ok': { color: '#56d364' },
  '&dark .cm-http-chip.tone-redirect': { color: '#58a6ff' },
  '&dark .cm-http-chip.tone-warn': { color: '#e3b341' },
  '&dark .cm-http-chip.tone-error': { color: '#ff7b72' },
});

export const http = () => new LanguageSupport(StreamLanguage.define(httpMode), [runState, runGutter, chipClicks, theme]);
