import { ViewPlugin, Decoration, EditorView } from '@codemirror/view';
import { RangeSetBuilder } from '@codemirror/state';

export const DELIMITERS = ['\t', ',', ';', '|'];
export const delimiterName = (d) => ({ '\t': 'tab', ',': 'comma', ';': 'semicolon', '|': 'pipe' })[d] ?? 'custom';

/** RFC 4180 parsing: quoted fields may hold delimiters, newlines and doubled quotes. */
export function parseCSV(text, delimiter) {
  const rows = [];
  let row = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } else quoted = false;
      } else field += ch;
    } else if (ch === '"' && field === '') {
      quoted = true;
    } else if (ch === delimiter) {
      row.push(field);
      field = '';
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') i++;
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else field += ch;
  }
  if (field !== '' || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

export function serializeCSV(rows, delimiter) {
  const needsQuotes = (v) => v.includes(delimiter) || v.includes('"') || v.includes('\n') || v.includes('\r')
    || /^\s|\s$/.test(v) && delimiter !== '\t';
  return rows
    .map((row) => row.map((v) => (needsQuotes(v) ? `"${v.replace(/"/g, '""')}"` : v)).join(delimiter))
    .join('\n');
}

/** Number of fields on one line, ignoring delimiters inside quotes. */
function fieldCount(line, delimiter) {
  let count = 1;
  let quoted = false;
  for (const ch of line) {
    if (ch === '"') quoted = !quoted;
    else if (ch === delimiter && !quoted) count++;
  }
  return count;
}

/**
 * The delimiter that splits every line into the same number of fields (the most fields wins),
 * or null when the text doesn't look tabular. A single line only counts when it has tabs, the
 * way spreadsheets put one copied row on the clipboard.
 */
export function detectDelimiter(text) {
  const lines = text.slice(0, 20000).split(/\r?\n/).filter((l) => l.trim() !== '').slice(0, 50);
  if (lines.length === 0) return null;
  let best = null;
  let bestFields = 1;
  for (const d of DELIMITERS) {
    const counts = lines.map((l) => fieldCount(l, d));
    const first = counts[0];
    if (first < 2) continue;
    const consistent = counts.filter((c) => c === first).length;
    if (consistent < Math.max(1, Math.ceil(lines.length * 0.9))) continue;
    if (lines.length === 1 && d !== '\t') continue;
    if (first > bestFields || (first === bestFields && d === '\t')) {
      best = d;
      bestFields = first;
    }
  }
  return best;
}

/** Rows from the first <table> in clipboard HTML (web pages, Numbers, Google Sheets). */
export function rowsFromHTML(html) {
  const doc = new DOMParser().parseFromString(html, 'text/html');
  const table = doc.querySelector('table');
  if (!table) return null;
  const rows = [...table.rows].map((r) => [...r.cells].map((c) => c.textContent.replace(/\s+/g, ' ').trim()));
  return rows.length ? rows : null;
}

// ---------- rainbow columns ----------

const columnMarks = Array.from({ length: 8 }, (_, i) => Decoration.mark({ class: `cm-csv-c${i}` }));
const separatorMark = Decoration.mark({ class: 'cm-csv-sep' });
const headerLine = Decoration.line({ class: 'cm-csv-header' });

const sniffDelimiter = (doc) => detectDelimiter(doc.sliceString(0, Math.min(doc.length, 8000))) ?? ',';

function decorate(view, d) {
  const builder = new RangeSetBuilder();
  const { doc } = view.state;
  let lastLine = 0;
  for (const { from, to } of view.visibleRanges) {
    let pos = from;
    while (pos <= to) {
      const line = doc.lineAt(pos);
      pos = line.to + 1;
      // Visible ranges can split one line (folds); decorations must be added in order, once.
      if (line.number <= lastLine) continue;
      lastLine = line.number;
      if (line.number === 1 && line.length > 0) builder.add(line.from, line.from, headerLine);
      let column = 0;
      let start = line.from;
      let quoted = false;
      // Only up to the end of the visible range: a long unwrapped line can be megabytes.
      const text = doc.sliceString(line.from, Math.min(line.to, to));
      for (let i = 0; i <= text.length; i++) {
        const ch = text[i];
        if (ch === '"') quoted = !quoted;
        if (i === text.length || (ch === d && !quoted)) {
          const end = line.from + i;
          if (end > start) builder.add(start, end, columnMarks[column % columnMarks.length]);
          if (i < text.length) builder.add(end, end + 1, separatorMark);
          column++;
          start = end + 1;
        }
      }
    }
  }
  return builder.finish();
}

const csvTheme = EditorView.baseTheme({
  '&light .cm-csv-c0': { color: '#0550ae' },
  '&light .cm-csv-c1': { color: '#953800' },
  '&light .cm-csv-c2': { color: '#116329' },
  '&light .cm-csv-c3': { color: '#8250df' },
  '&light .cm-csv-c4': { color: '#a40e26' },
  '&light .cm-csv-c5': { color: '#0a7b83' },
  '&light .cm-csv-c6': { color: '#7d4e00' },
  '&light .cm-csv-c7': { color: '#57606a' },
  '&dark .cm-csv-c0': { color: '#61afef' },
  '&dark .cm-csv-c1': { color: '#e5c07b' },
  '&dark .cm-csv-c2': { color: '#98c379' },
  '&dark .cm-csv-c3': { color: '#c678dd' },
  '&dark .cm-csv-c4': { color: '#e06c75' },
  '&dark .cm-csv-c5': { color: '#56b6c2' },
  '&dark .cm-csv-c6': { color: '#d19a66' },
  '&dark .cm-csv-c7': { color: '#abb2bf' },
  '.cm-csv-sep': { opacity: '0.45' },
  '.cm-csv-header': { fontWeight: '600' },
});

/** Colours each column differently; `delimiter` null means detect it from the document. */
export function csv(delimiter = null) {
  const plugin = ViewPlugin.fromClass(class {
    constructor(view) {
      this.delimiter = delimiter ?? sniffDelimiter(view.state.doc);
      this.decorations = decorate(view, this.delimiter);
    }
    update(u) {
      if (!delimiter && u.docChanged && u.changes.touchesRange(0, 8000)) this.delimiter = sniffDelimiter(u.state.doc);
      if (u.docChanged || u.viewportChanged) this.decorations = decorate(u.view, this.delimiter);
    }
  }, { decorations: (v) => v.decorations });
  return [plugin, csvTheme];
}
