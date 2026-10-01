// Diff scratch file format (mirrored by Sources/ScratchPad/DiffFile.swift):
//
//   --- syntax: json        (optional)
//   --- left: Original
//   …left text…
//   --- right: Modified
//   …right text…
//
// Content lines that look like a header get one extra leading backslash.

const HEADER = /^--- (left|right|syntax):[ \t]?(.*)$/;
const ESCAPED = /^\\+--- (left|right|syntax):/;

const escapeText = (text) => text.split('\n').map((l) => (/^\\*--- (left|right|syntax):/.test(l) ? '\\' + l : l)).join('\n');
const unescapeLine = (l) => (ESCAPED.test(l) ? l.slice(1) : l);

export const isDiffText = (text) => /^--- (left|syntax):/.test(text);

export function parseDiff(text) {
  const doc = { syntax: 'text', leftName: 'Original', rightName: 'Modified', left: '', right: '' };
  if (!isDiffText(text)) {
    doc.left = text;
    return doc;
  }
  let side = null;
  const buf = { left: [], right: [] };
  for (const line of text.split('\n')) {
    const m = side === 'right' ? null : HEADER.exec(line);
    if (side === null) {
      if (m?.[1] === 'syntax') doc.syntax = m[2].trim() || 'text';
      else if (m?.[1] === 'left') {
        side = 'left';
        doc.leftName = m[2];
      }
    } else if (side === 'left' && m?.[1] === 'right') {
      side = 'right';
      doc.rightName = m[2];
    } else {
      buf[side].push(unescapeLine(line));
    }
  }
  doc.left = buf.left.join('\n');
  doc.right = buf.right.join('\n');
  return doc;
}

export function serializeDiff({ syntax, leftName, rightName, left, right }) {
  const head = syntax && syntax !== 'text' ? `--- syntax: ${syntax}\n` : '';
  return `${head}--- left: ${leftName}\n${escapeText(left)}\n--- right: ${rightName}\n${escapeText(right)}`;
}
