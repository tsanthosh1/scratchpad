// Token-preserving JSON formatter: numbers, escapes and key order are copied verbatim,
// so values like 12345678901234567890 survive formatting unchanged.

export class JsonError extends Error {
  constructor(message, pos) {
    super(message);
    this.pos = pos;
  }
}

const NUMBER = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/y;

export function formatJson(src, indentUnit) {
  const compact = indentUnit == null;
  let i = 0;

  const ws = () => {
    while (i < src.length) {
      const c = src.charCodeAt(i);
      if (c === 32 || c === 9 || c === 10 || c === 13 || c === 0xfeff) i++;
      else break;
    }
  };
  const fail = (msg) => {
    throw new JsonError(msg, i);
  };
  const nl = (depth) => (compact ? '' : '\n' + indentUnit.repeat(depth));

  const string = () => {
    const start = i++;
    while (i < src.length) {
      const c = src[i];
      if (c === '"') return src.slice(start, ++i);
      if (c === '\\') i += 2;
      else if (c === '\n') fail('Unterminated string');
      else i++;
    }
    i = start;
    fail('Unterminated string');
  };

  const value = (depth) => {
    ws();
    if (i >= src.length) fail('Unexpected end of input');
    const c = src[i];
    if (c === '{') return container(depth, '{', '}', true);
    if (c === '[') return container(depth, '[', ']', false);
    if (c === '"') return string();
    if (c === '-' || (c >= '0' && c <= '9')) {
      NUMBER.lastIndex = i;
      const m = NUMBER.exec(src);
      if (!m) fail('Invalid number');
      i += m[0].length;
      return m[0];
    }
    for (const lit of ['true', 'false', 'null']) {
      if (src.startsWith(lit, i)) {
        i += lit.length;
        return lit;
      }
    }
    fail(`Unexpected character '${c}'`);
  };

  const container = (depth, open, close, isObject) => {
    i++;
    ws();
    if (src[i] === close) {
      i++;
      return open + close;
    }
    const items = [];
    for (;;) {
      ws();
      let item = '';
      if (isObject) {
        if (src[i] !== '"') fail('Expected property name');
        item = string();
        ws();
        if (src[i] !== ':') fail("Expected ':'");
        i++;
        item += compact ? ':' : ': ';
      }
      item += value(depth + 1);
      items.push(item);
      ws();
      if (src[i] === ',') {
        i++;
        continue;
      }
      if (src[i] === close) {
        i++;
        break;
      }
      fail(`Expected ',' or '${close}'`);
    }
    return open + nl(depth + 1) + items.join(',' + nl(depth + 1)) + nl(depth) + close;
  };

  const out = value(0);
  ws();
  if (i < src.length) fail('Unexpected content after JSON value');
  return out;
}
