// "Go to Symbol": the outline of a document, for every file type the editor knows.
// Languages with a Lezer grammar are read from the syntax tree; the others (legacy modes, HTTP, SQL statements,
// tables, plain text) from their lines. Each symbol is { name, kind, from, to, end, depth, container, detail }:
// from–to is what gets selected (usually the name), end is where the symbol's body ends.
import { syntaxTree, ensureSyntaxTree } from '@codemirror/language';
import { detectDelimiter } from './csv.js';

const MAX_SYMBOLS = 20_000;
const PARSE_BUDGET_MS = 400;

class Collector {
  constructor(state) {
    this.state = state;
    this.list = [];
    this.stack = [];
    this.full = false;
  }

  /** Nesting follows the source ranges: a symbol is inside every earlier one whose body contains its start. */
  add(s) {
    if (this.list.length >= MAX_SYMBOLS) {
      this.full = true;
      return;
    }
    const start = s.start ?? s.from;
    while (this.stack.length && this.stack[this.stack.length - 1].end <= start) this.stack.pop();
    this.push(s);
  }

  /** Nesting follows explicit levels (heading 1 > heading 2, table > column…); bodies end at the next peer. */
  addLevel(s, level) {
    if (this.list.length >= MAX_SYMBOLS) {
      this.full = true;
      return;
    }
    while (this.stack.length && this.stack[this.stack.length - 1].level >= level) {
      this.stack.pop().end = Math.max(s.from - 1, 0);
    }
    this.push({ ...s, level, end: this.state.doc.length });
  }

  push(s) {
    const parent = this.stack[this.stack.length - 1];
    const symbol = {
      name: clip(s.name.replace(/\s+/g, ' ').trim() || '(anonymous)', 120),
      kind: s.kind,
      from: s.from,
      to: s.to ?? s.from,
      end: s.end ?? s.to ?? s.from,
      depth: this.stack.length,
      container: s.container ?? parent?.name ?? '',
      detail: s.detail ? clip(s.detail.replace(/\s+/g, ' ').trim(), 80) : '',
    };
    this.list.push(symbol);
    this.stack.push({ ...symbol, level: s.level });
  }
}

const clip = (text, max) => (text.length > max ? text.slice(0, max - 1) + '…' : text);
const unquote = (text) => {
  const t = text.trim();
  if (t.length >= 2 && (t[0] === '"' || t[0] === "'") && t[t.length - 1] === t[0]) {
    try {
      return t[0] === '"' ? JSON.parse(t) : t.slice(1, -1).replace(/''/g, "'");
    } catch {
      return t.slice(1, -1);
    }
  }
  return t;
};

// ---------- syntax trees ----------

const kid = (node, ...names) => {
  for (let c = node.firstChild; c; c = c.nextSibling) if (names.includes(c.name)) return c;
  return null;
};
const kids = (node, ...names) => {
  const out = [];
  for (let c = node.firstChild; c; c = c.nextSibling) if (names.includes(c.name)) out.push(c);
  return out;
};
/** First descendant with one of the names, not looking inside `skip` nodes (such as function bodies). */
const find = (node, names, skip = []) => {
  for (let c = node.firstChild; c; c = c.nextSibling) {
    if (names.includes(c.name)) return c;
    if (skip.includes(c.name)) continue;
    const found = find(c, names, skip);
    if (found) return found;
  }
  return null;
};
const within = (node, names) => {
  for (let p = node.parent; p; p = p.parent) if (names.includes(p.name)) return true;
  return false;
};

/** The whole document's syntax tree, parsing the rest within a time budget; a cut-off parse is flagged. */
function parsed(state, out) {
  const budget = Math.min(2500, PARSE_BUDGET_MS + state.doc.length / 4000);
  const tree = ensureSyntaxTree(state, state.doc.length, budget) ?? syntaxTree(state);
  if (tree.length < state.doc.length) out.partial = true;
  return tree;
}

function walk(state, out, rules) {
  const tree = parsed(state, out);
  const ctx = {
    state,
    text: (n) => state.sliceDoc(n.from, n.to),
    counters: new Map(),
    sym(nameNode, kind, extra = {}) {
      return nameNode ? { name: state.sliceDoc(nameNode.from, nameNode.to), kind, from: nameNode.from, to: nameNode.to, ...extra } : null;
    },
    /** Position of a value in its array, counted as the walk passes each element. */
    index(node) {
      const key = node.parent.from;
      const i = ctx.counters.get(key) ?? 0;
      ctx.counters.set(key, i + 1);
      return i;
    },
  };
  tree.iterate({
    enter(ref) {
      if (out.full) return false;
      const rule = rules[ref.name];
      if (!rule) return undefined;
      const result = rule(ref.node, ctx);
      if (result === false) return false;
      if (!result) return undefined;
      // A list (several variables in one declaration…) has nothing worth listing inside it, and its entries
      // are siblings: each spans only itself.
      if (Array.isArray(result)) {
        for (const s of result) if (s) out.add({ start: s.from, end: s.to, ...s });
        return false;
      }
      if (result.name !== undefined) out.add({ start: ref.from, end: ref.to, ...result });
      return undefined;
    },
  });
}

const JS_FUNCTIONS = ['FunctionDeclaration', 'FunctionExpression', 'ArrowFunction', 'MethodDeclaration'];
const TEST_CALLS = new Set(['describe', 'context', 'suite', 'it', 'test', 'specify', 'beforeAll', 'afterAll', 'beforeEach', 'afterEach']);

const jsRules = {
  ClassDeclaration: (n, c) => c.sym(kid(n, 'VariableDefinition', 'TypeDefinition'), 'class'),
  ClassExpression: (n, c) => c.sym(kid(n, 'VariableDefinition'), 'class'),
  FunctionDeclaration: (n, c) => c.sym(kid(n, 'VariableDefinition'), 'function')
    ?? { name: 'default', kind: 'function', from: n.from, to: n.from },
  MethodDeclaration: (n, c) => {
    const name = kid(n, 'PropertyDefinition', 'PrivatePropertyDefinition', 'PropertyName', 'String');
    if (!name) return null;
    const accessor = kid(n, 'get', 'set');
    const kind = c.text(name) === 'constructor' ? 'constructor' : 'method';
    return c.sym(name, kind, { detail: [accessor?.name, kid(n, 'static') && 'static', kid(n, 'async') && 'async'].filter(Boolean).join(' ') });
  },
  PropertyDeclaration: (n, c) => c.sym(kid(n, 'PropertyDefinition', 'PrivatePropertyDefinition'),
    kid(n, 'ArrowFunction', 'FunctionExpression') ? 'method' : 'property'),
  InterfaceDeclaration: (n, c) => c.sym(kid(n, 'TypeDefinition'), 'interface'),
  PropertyType: (n, c) => c.sym(kid(n, 'PropertyDefinition'), 'property'),
  MethodType: (n, c) => c.sym(kid(n, 'PropertyDefinition'), 'method'),
  TypeAliasDeclaration: (n, c) => c.sym(kid(n, 'TypeDefinition'), 'type'),
  EnumDeclaration: (n, c) => c.sym(kid(n, 'TypeDefinition', 'VariableDefinition'), 'enum'),
  EnumBody: (n, c) => kids(n, 'PropertyName').map((p) => c.sym(p, 'enumMember')),
  NamespaceDeclaration: (n, c) => c.sym(kid(n, 'VariableDefinition', 'String', 'PropertyName'), 'namespace'),
  ModuleDeclaration: (n, c) => c.sym(kid(n, 'VariableDefinition', 'String', 'PropertyName'), 'namespace'),
  VariableDeclaration: (n, c) => {
    // Locals inside functions are noise; module- and namespace-level declarations are the outline.
    if (within(n, JS_FUNCTIONS)) return false;
    const constant = !!kid(n, 'const');
    const out = [];
    for (let d = n.firstChild; d; d = d.nextSibling) {
      if (d.name !== 'VariableDefinition') continue;
      let value = d.nextSibling;
      if (value?.name === 'TypeAnnotation') value = value.nextSibling;
      if (value?.name === 'Equals') value = value.nextSibling;
      const kind = ['ArrowFunction', 'FunctionExpression'].includes(value?.name) ? 'function'
        : value?.name === 'ClassExpression' ? 'class' : constant ? 'constant' : 'variable';
      out.push(c.sym(d, kind, { end: value?.to ?? d.to }));
    }
    return out;
  },
  // describe('…', () => { it('…') }) — test suites read like an outline, as in VS Code.
  CallExpression: (n, c) => {
    const callee = n.firstChild;
    if (!callee) return null;
    const head = c.text(callee);
    const base = head.split('.')[0];
    if (!TEST_CALLS.has(base) || head.length > 30) return null;
    const args = kid(n, 'ArgList');
    const title = args && kid(args, 'String', 'TemplateString');
    if (!title && !base.startsWith('before') && !base.startsWith('after')) return null;
    return title ? { name: `${head} ${unquote(c.text(title).replace(/^`|`$/g, '"'))}`, kind: 'test', from: title.from, to: title.to }
      : { name: head, kind: 'test', from: callee.from, to: callee.to };
  },
};

const javaDef = (kind) => (n, c) => c.sym(kid(n, 'Definition'), kind);
const javaRules = {
  ClassDeclaration: javaDef('class'),
  InterfaceDeclaration: javaDef('interface'),
  EnumDeclaration: javaDef('enum'),
  RecordDeclaration: javaDef('class'),
  AnnotationTypeDeclaration: (n, c) => c.sym(kid(n, 'Identifier', 'Definition'), 'interface'),
  MethodDeclaration: (n, c) => {
    // The grammar reads `record R(int a) {}` as a method whose return type is "record".
    const type = kid(n, 'TypeName');
    const isRecord = type && c.text(type) === 'record';
    return c.sym(kid(n, 'Definition'), isRecord ? 'class' : 'method', isRecord ? { detail: 'record' } : {});
  },
  ConstructorDeclaration: javaDef('constructor'),
  FieldDeclaration: (n, c) => {
    const modifiers = kid(n, 'Modifiers');
    const m = modifiers ? c.text(modifiers) : '';
    const kind = /\bstatic\b/.test(m) && /\bfinal\b/.test(m) ? 'constant' : 'field';
    return kids(n, 'VariableDeclarator').map((v) => c.sym(kid(v, 'Definition'), kind));
  },
  ConstantDeclaration: (n, c) => kids(n, 'VariableDeclarator').map((v) => c.sym(kid(v, 'Definition'), 'constant')),
  EnumConstant: javaDef('enumMember'),
};

const pythonInClass = (n) => {
  let p = n.parent;
  if (p?.name === 'DecoratedStatement') p = p.parent;
  return p?.name === 'Body' && p.parent?.name === 'ClassDefinition';
};
const pythonRules = {
  ClassDefinition: (n, c) => c.sym(kid(n, 'VariableName'), 'class'),
  FunctionDefinition: (n, c) => {
    const name = kid(n, 'VariableName');
    const kind = pythonInClass(n) ? (name && c.text(name) === '__init__' ? 'constructor' : 'method') : 'function';
    return c.sym(name, kind, { detail: kid(n, 'async') ? 'async' : '' });
  },
  AssignStatement: (n, c) => {
    if (within(n, ['FunctionDefinition', 'LambdaExpression'])) return false;
    const inClass = within(n, ['ClassDefinition']);
    const out = [];
    for (let v = n.firstChild; v && v.name !== 'AssignOp'; v = v.nextSibling) {
      if (v.name !== 'VariableName') continue;
      const name = c.text(v);
      out.push(c.sym(v, inClass ? 'field' : /^[A-Z][A-Z0-9_]*$/.test(name) ? 'constant' : 'variable'));
    }
    return out;
  },
};

const goRules = {
  TypeSpec: (n, c) => {
    const type = kid(n, 'StructType', 'InterfaceType');
    return c.sym(kid(n, 'DefName'), type?.name === 'StructType' ? 'struct' : type ? 'interface' : 'type');
  },
  FieldDecl: (n, c) => kids(n, 'FieldName').map((f) => c.sym(f, 'field')),
  MethodElem: (n, c) => c.sym(kid(n, 'FieldName'), 'method'),
  FunctionDecl: (n, c) => c.sym(kid(n, 'DefName'), 'function'),
  MethodDecl: (n, c) => {
    const receiver = kid(n, 'Parameters');
    const type = receiver && find(receiver, ['TypeName']);
    return c.sym(kid(n, 'FieldName'), 'method', type ? { container: c.text(type), detail: c.text(receiver) } : {});
  },
  ConstSpec: (n, c) => (within(n, ['Block']) ? false : kids(n, 'DefName').map((d) => c.sym(d, 'constant'))),
  VarSpec: (n, c) => (within(n, ['Block']) ? false : kids(n, 'DefName').map((d) => c.sym(d, 'variable'))),
};

const rustId = (names, kind) => (n, c) => c.sym(kid(n, ...names), kind);
const rustRules = {
  ModItem: rustId(['BoundIdentifier', 'Identifier'], 'module'),
  FunctionItem: (n, c) => c.sym(kid(n, 'BoundIdentifier'),
    ['ImplItem', 'TraitItem'].includes(n.parent?.parent?.name) ? 'method' : 'function'),
  FunctionSignatureItem: rustId(['BoundIdentifier'], 'method'),
  StructItem: rustId(['TypeIdentifier'], 'struct'),
  UnionItem: rustId(['TypeIdentifier'], 'struct'),
  EnumItem: rustId(['TypeIdentifier'], 'enum'),
  EnumVariant: rustId(['Identifier'], 'enumMember'),
  TraitItem: rustId(['TypeIdentifier'], 'interface'),
  ImplItem: (n, c) => {
    const body = kid(n, 'DeclarationList');
    const head = c.state.sliceDoc(n.from, body ? body.from : n.to).replace(/^\s*(unsafe\s+)?impl\s*(<[^>]*>)?\s*/, '');
    const first = kid(n, 'TypeIdentifier', 'GenericType', 'ScopedTypeIdentifier');
    return { name: `impl ${head}`, kind: 'class', from: first?.from ?? n.from, to: first?.to ?? n.from };
  },
  ConstItem: rustId(['BoundIdentifier'], 'constant'),
  StaticItem: rustId(['BoundIdentifier'], 'constant'),
  TypeItem: rustId(['TypeIdentifier'], 'type'),
  MacroDefinition: (n, c) => {
    const s = c.sym(kid(n, 'Identifier'), 'function');
    return s && { ...s, name: s.name + '!' };
  },
  FieldDeclaration: (n, c) => (within(n, ['StructItem', 'UnionItem']) ? c.sym(kid(n, 'FieldIdentifier'), 'field') : null),
};

const CPP_NAMES = ['Identifier', 'FieldIdentifier', 'ScopedIdentifier', 'DestructorName', 'OperatorName', 'QualifiedIdentifier', 'TemplateFunction'];
const cppFunctionName = (node) => {
  const declarator = find(node, ['FunctionDeclarator'], ['CompoundStatement', 'FieldDeclarationList', 'InitDeclarator']);
  return declarator && kid(declarator, ...CPP_NAMES);
};
const cppRules = {
  NamespaceDefinition: (n, c) => c.sym(kid(n, 'Identifier', 'NamespaceIdentifier'), 'namespace'),
  ClassSpecifier: (n, c) => (kid(n, 'FieldDeclarationList') ? c.sym(kid(n, 'TypeIdentifier'), 'class') : null),
  StructSpecifier: (n, c) => (kid(n, 'FieldDeclarationList') ? c.sym(kid(n, 'TypeIdentifier'), 'struct') : null),
  UnionSpecifier: (n, c) => (kid(n, 'FieldDeclarationList') ? c.sym(kid(n, 'TypeIdentifier'), 'struct') : null),
  EnumSpecifier: (n, c) => (kid(n, 'EnumeratorList') ? c.sym(kid(n, 'TypeIdentifier'), 'enum') : null),
  Enumerator: (n, c) => c.sym(kid(n, 'Identifier'), 'enumMember'),
  FunctionDefinition: (n, c) => {
    const name = cppFunctionName(n);
    const method = name?.name === 'ScopedIdentifier' || within(n, ['FieldDeclarationList']);
    return c.sym(name, method ? 'method' : 'function');
  },
  FieldDeclaration: (n, c) => {
    const fn = cppFunctionName(n);
    if (fn) return [c.sym(fn, 'method')];
    return kids(n, 'FieldIdentifier').map((f) => c.sym(f, 'field'));
  },
  Declaration: (n, c) => {
    if (within(n, ['FunctionDefinition'])) return false;
    const fn = cppFunctionName(n);
    if (fn) return [c.sym(fn, within(n, ['FieldDeclarationList']) ? 'constructor' : 'function')];
    const names = kids(n, 'Identifier', 'InitDeclarator').map((d) => (d.name === 'InitDeclarator' ? kid(d, 'Identifier') : d));
    return names.map((d) => c.sym(d, 'variable'));
  },
  TypeDefinition: (n, c) => {
    const names = kids(n, 'TypeIdentifier');
    return [c.sym(names[names.length - 1], 'type')];
  },
  PreprocDirective: (n, c) => (/^#\s*define\b/.test(c.text(n)) ? [c.sym(kid(n, 'Identifier'), 'constant')] : false),
};

const selectorEnd = (state, from, to) => {
  let end = to;
  while (end > from && /\s/.test(state.sliceDoc(end - 1, end))) end--;
  return end;
};
const atRule = (n, c) => {
  const body = kid(n, 'Block', 'KeyframeList');
  const to = selectorEnd(c.state, n.from, body ? body.from : n.to);
  return { name: c.state.sliceDoc(n.from, to).replace(/;$/, ''), kind: 'atRule', from: n.from, to };
};
const cssRules = {
  RuleSet: (n, c) => {
    const body = kid(n, 'Block');
    const to = selectorEnd(c.state, n.from, body ? body.from : n.to);
    return { name: c.state.sliceDoc(n.from, to), kind: 'selector', from: n.from, to };
  },
  MediaStatement: atRule,
  SupportsStatement: atRule,
  KeyframesStatement: atRule,
  ImportStatement: atRule,
  AtRule: atRule,
  // Custom properties (--brand: …) are the variables of a stylesheet.
  Declaration: (n, c) => {
    const name = n.firstChild;
    return name?.name === 'VariableName' ? [c.sym(name, 'variable')] : false;
  },
};

// ---- data: JSON / YAML ----

const LABEL_KEYS = ['name', 'id', 'title', 'key', 'kind', 'type', 'label', 'operationId'];

/**
 * JSON is scanned directly rather than read from the syntax tree: multi-megabyte files are common in a scratch pad
 * and one pass over the text is far quicker than a full parse. Comments (JSONC) are skipped.
 */
function jsonSymbols(state, out) {
  const text = state.doc.toString();
  const n = text.length;
  // One frame per open object/array: arrays count their items; objects remember the key awaiting its value.
  const frames = [];
  let i = 0;
  const skipSpace = () => {
    for (;;) {
      while (i < n && (text.charCodeAt(i) <= 32 || text[i] === ',')) i++;
      if (text[i] === '/' && text[i + 1] === '/') {
        while (i < n && text[i] !== '\n') i++;
      } else if (text[i] === '/' && text[i + 1] === '*') {
        const end = text.indexOf('*/', i + 2);
        i = end < 0 ? n : end + 2;
      } else {
        return;
      }
    }
  };
  const stringEnd = (from) => {
    let j = from + 1;
    while (j < n && text[j] !== '"') j += text[j] === '\\' ? 2 : 1;
    return Math.min(j + 1, n);
  };
  const scalarEnd = (from) => {
    if (text[from] === '"') return stringEnd(from);
    let j = from;
    while (j < n && !',]}\n\r \t'.includes(text[j])) j++;
    return j;
  };
  const kindOf = (ch) => (ch === '{' ? 'object' : ch === '[' ? 'array' : ch === '"' ? 'string'
    : ch === 't' || ch === 'f' ? 'boolean' : ch === 'n' ? 'null' : 'number');
  const open = (ch, symbol) => frames.push({ array: ch === '[', index: 0, symbol, labelRank: LABEL_KEYS.length });
  while (i < n && !out.full) {
    skipSpace();
    if (i >= n) break;
    const ch = text[i];
    const frame = frames[frames.length - 1];
    if (ch === '}' || ch === ']') {
      frames.pop();
      i++;
      continue;
    }
    if (frame && !frame.array) {
      // A key, then its value.
      if (ch !== '"') { i++; continue; }
      const keyEnd = stringEnd(i);
      const name = unquote(text.slice(i, keyEnd));
      const keyFrom = i;
      i = keyEnd;
      skipSpace();
      if (text[i] === ':') i++;
      skipSpace();
      const v = text[i];
      const kind = kindOf(v);
      if (kind === 'object' || kind === 'array') {
        out.addLevel({ name, kind, from: keyFrom, to: keyEnd }, frames.length - 1);
        open(v, out.list[out.list.length - 1]);
        i++;
      } else {
        const end = scalarEnd(i);
        const value = unquote(text.slice(i, Math.min(end, i + 200)));
        out.addLevel({ name, kind, from: keyFrom, to: keyEnd, detail: value }, frames.length - 1);
        // An object in an array is labelled with its "name" / "id" / … value.
        const rank = LABEL_KEYS.indexOf(name);
        const owner = frames.length >= 2 && frames[frames.length - 2].array ? frame : null;
        if (owner?.symbol && rank >= 0 && rank < owner.labelRank && (kind === 'string' || kind === 'number')) {
          owner.labelRank = rank;
          owner.symbol.detail = clip(value, 80);
        }
        i = end;
      }
      continue;
    }
    // A value: the document root or an array element.
    const index = frame ? frame.index++ : 0;
    if (ch === '{' || ch === '[') {
      let symbol = null;
      if (frame) {
        out.addLevel({ name: `[${index}]`, kind: kindOf(ch), from: i, to: i }, frames.length - 1);
        symbol = out.list[out.list.length - 1];
      }
      open(ch, symbol);
      i++;
    } else {
      i = Math.max(scalarEnd(i), i + 1);
    }
  }
}

/**
 * YAML is scanned line by line from its indentation rather than read from the Lezer tree: that grammar takes a "{"
 * inside a plain key (OpenAPI's "/v1/{id}/charges:") for a flow mapping and loses the rest of the file, and big specs
 * would otherwise hit the parse budget.
 */
const YAML_KEY = /^(?:"((?:[^"\\]|\\.)*)"|'((?:[^']|'')*)'|([^\s#&*!|>'"%@`{[\]},-][^#]*?|-[^\s#][^#]*?))[ \t]*:(?=[ \t]|$)/;
const YAML_PROPS = /^(?:[&!][^\s]*[ \t]+)*(?:[&!][^\s]*)?/;

function yamlSymbols(state, out) {
  const text = state.doc.toString();
  const lines = [];
  for (let from = 0; from <= text.length; ) {
    const nl = text.indexOf('\n', from);
    const to = nl < 0 ? text.length : nl;
    lines.push({ from, text: text.slice(from, to).replace(/\r$/, '') });
    from = to + 1;
  }
  const isBlank = (t) => /^\s*(#.*)?$/.test(t);
  const isSeparator = (t) => /^---(\s|$)/.test(t) || /^\.\.\.\s*$/.test(t);
  const indentOf = (t) => t.length - t.trimStart().length;
  const stripComment = (v) => v.replace(/(^|[ \t])#.*$/, '').trim();

  let documents = 0;
  for (let i = 0, content = false; i <= lines.length; i++) {
    const t = lines[i]?.text;
    if (t === undefined || isSeparator(t)) {
      if (content) documents++;
      content = false;
    } else if (!isBlank(t) && !t.startsWith('%')) {
      content = true;
    }
  }
  const multi = documents > 1;

  // Open blocks, innermost last. A sequence written at its key's own indent gets col - 0.5 so its "-" items nest.
  let frames = [];
  let doc = null;
  let docIndex = 0;
  let rootIndex = 0;
  const base = () => (multi ? 1 : 0);

  // What follows a key with no value on its line: a nested mapping, a sequence, or nothing.
  const nestedKind = (i, col) => {
    for (let j = i + 1; j < lines.length; j++) {
      const t = lines[j].text;
      if (isBlank(t)) continue;
      if (isSeparator(t)) return null;
      const ind = indentOf(t);
      const rest = t.slice(ind);
      if (rest.startsWith('- ') || rest === '-') return ind >= col ? { kind: 'array', sameIndent: ind === col } : null;
      return ind > col ? { kind: 'object' } : null;
    }
    return null;
  };
  const emit = (symbol, level) => {
    out.addLevel(symbol, level);
    return out.full ? null : out.list[out.list.length - 1];
  };
  const labelItem = (name, value) => {
    const owner = frames[frames.length - 1];
    if (!owner?.item || !owner.symbol) return;
    const rank = LABEL_KEYS.indexOf(name);
    if (rank >= 0 && rank < owner.labelRank && value) {
      owner.labelRank = rank;
      owner.symbol.detail = clip(value, 80);
    }
  };
  // `{ summary: Cancel payout, x: [1] }` on one line: its top-level keys become children.
  const flowPairs = (body, from, level) => {
    let depth = 0, quote = '', start = 0;
    const parts = [];
    for (let k = 0; k <= body.length; k++) {
      const ch = body[k];
      if (quote) { if (ch === quote) quote = ''; continue; }
      if (ch === '"' || ch === "'") quote = ch;
      else if (ch === '{' || ch === '[') depth++;
      else if (ch === '}' || ch === ']') depth--;
      else if ((ch === ',' && depth === 0) || k === body.length) { parts.push([start, k]); start = k + 1; }
    }
    for (const [a, b] of parts) {
      const raw = body.slice(a, b);
      const lead = raw.length - raw.trimStart().length;
      const m = YAML_KEY.exec(raw.trimStart());
      if (!m) continue;
      const value = raw.trimStart().slice(m[0].length).trim();
      const kind = value.startsWith('{') ? 'object' : value.startsWith('[') ? 'array' : 'key';
      const keyText = m[0].replace(/[ \t]*:$/, '');
      emit({ name: yamlKeyName(m), kind, from: from + a + lead, to: from + a + lead + keyText.length,
             detail: kind === 'key' ? unquote(value) : '' }, level);
    }
  };

  for (let i = 0; i < lines.length && !out.full; i++) {
    const { from, text: line } = lines[i];
    if (isSeparator(line)) {
      frames = [];
      doc = null;
      rootIndex = 0;
      continue;
    }
    if (isBlank(line) || (line.startsWith('%') && !doc)) continue;
    if (multi && !doc) {
      doc = emit({ name: `Document ${docIndex + 1}`, kind: 'document', from, to: from }, 0);
      if (doc) doc.meta = { index: docIndex++ };
    }
    let col = indentOf(line);
    let rest = line.slice(col);

    // Sequence entries: "- ", possibly several on one line ("- - a").
    let isKeyLine = true;
    while (rest === '-' || rest.startsWith('- ') || rest.startsWith('-\t')) {
      while (frames.length && frames[frames.length - 1].col >= col) frames.pop();
      const parent = frames[frames.length - 1];
      const index = parent ? parent.index++ : rootIndex++;
      const after = rest.slice(1);
      const valueCol = col + 1 + (after.length - after.trimStart().length);
      const value = stripComment(after.trimStart().replace(YAML_PROPS, ''));
      let kind = null;
      if (!value) kind = nestedKind(i, col)?.kind ?? null;
      else if (value.startsWith('{') || YAML_KEY.test(value)) kind = 'object';
      else if (value.startsWith('[') || value === '-' || value.startsWith('- ')) kind = 'array';
      if (!kind) { isKeyLine = false; break; }
      const symbol = emit({ name: `[${index}]`, kind, from: from + valueCol, to: from + valueCol }, frames.length + base());
      frames.push({ col, symbol, item: true, index: 0, labelRank: LABEL_KEYS.length });
      if (value.startsWith('{')) { flowPairs(value.replace(/^\{|\}$/g, ''), from + valueCol + 1, frames.length + base()); isKeyLine = false; break; }
      if (!value) { isKeyLine = false; break; }
      col = valueCol;
      rest = line.slice(col);
    }
    if (!isKeyLine) continue;

    const m = YAML_KEY.exec(rest);
    if (!m) continue;
    while (frames.length && frames[frames.length - 1].col >= col - 0.5) frames.pop();
    const name = yamlKeyName(m);
    const keyText = m[0].replace(/[ \t]*:$/, '');
    const rawValue = rest.slice(m[0].length);
    const value = stripComment(rawValue.trimStart().replace(YAML_PROPS, ''));
    const level = frames.length + base();
    const range = { from: from + col, to: from + col + keyText.length };
    if (!value) {
      const nested = nestedKind(i, col);
      const symbol = emit({ name, kind: nested?.kind ?? 'key', ...range }, level);
      if (nested) frames.push({ col: nested.sameIndent ? col - 0.5 : col, symbol, index: 0 });
    } else if (value.startsWith('{') || value.startsWith('[')) {
      const kind = value.startsWith('{') ? 'object' : 'array';
      emit({ name, kind, ...range }, level);
      if (kind === 'object' && value.endsWith('}')) flowPairs(value.slice(1, -1), from + line.indexOf('{') + 1, level + 1);
      // A flow collection over several lines: skip to where its brackets balance.
      let depth = 0;
      for (const ch of value.replace(/"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'/g, '')) depth += '{['.includes(ch) ? 1 : '}]'.includes(ch) ? -1 : 0;
      while (depth > 0 && i + 1 < lines.length) {
        i++;
        for (const ch of stripComment(lines[i].text).replace(/"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'/g, '')) depth += '{['.includes(ch) ? 1 : '}]'.includes(ch) ? -1 : 0;
      }
    } else if (/^[|>][-+0-9]*$/.test(value)) {
      emit({ name, kind: 'key', ...range }, level);
      // Block scalar: its lines are text, however they look.
      while (i + 1 < lines.length && (lines[i + 1].text.trim() === '' || indentOf(lines[i + 1].text) > col)) i++;
    } else {
      const detail = unquote(value.length > 200 ? value.slice(0, 200) : value);
      emit({ name, kind: 'key', ...range, detail }, level);
      labelItem(name, detail);
      if (doc) {
        const depth = frames.length;
        if (depth === 0 && name === 'kind') doc.meta.kind = detail;
        if (depth === 1 && name === 'name' && frames[0].symbol?.name === 'metadata') doc.meta.name = detail;
        const { kind: k, name: n, index } = doc.meta;
        doc.name = k ? `${k}${n ? ' ' + n : ''}` : `Document ${index + 1}`;
      }
      // A quoted or plain scalar continued on more-indented lines.
      while (i + 1 < lines.length && !isBlank(lines[i + 1].text) && indentOf(lines[i + 1].text) > col
             && !YAML_KEY.test(lines[i + 1].text.trimStart()) && !/^-(\s|$)/.test(lines[i + 1].text.trimStart())) i++;
    }
  }
  for (const symbol of out.list) delete symbol.meta;
  fixContainers(out.list);
}

const yamlKeyName = (m) => (m[1] !== undefined ? unquote(`"${m[1]}"`) : m[2] !== undefined ? m[2].replace(/''/g, "'") : m[3].trim());

/** Containers name the parent as it ended up (document and operation names are only known later). */
function fixContainers(symbols) {
  const names = [];
  for (const s of symbols) {
    names.length = s.depth;
    s.container = s.depth > 0 ? names[s.depth - 1] ?? '' : '';
    names.push(s.name);
  }
}

const HTTP_METHODS = ['get', 'put', 'post', 'delete', 'patch', 'options', 'head', 'trace'];
/** OpenAPI specs read better as operations ("GET /pets") and schemas than as raw keys. */
function openapiOutline(symbols) {
  const path = [];
  symbols.forEach((s, i) => {
    path.length = s.depth;
    path.push(s.name);
    const [root, second] = path;
    if (root === 'paths' && s.depth === 1) {
      s.kind = 'route';
    } else if (root === 'paths' && s.depth === 2 && HTTP_METHODS.includes(s.name.toLowerCase())) {
      s.name = `${s.name.toUpperCase()} ${path[1]}`;
      s.kind = 'operation';
      for (let j = i + 1; j < symbols.length && symbols[j].depth > s.depth; j++) {
        const child = symbols[j];
        if (child.depth === s.depth + 1 && (child.name === 'summary' || child.name === 'operationId') && child.detail) {
          s.detail = child.detail;
          if (child.name === 'summary') break;
        }
      }
    } else if (s.depth === 2 && root === 'components' && second === 'schemas') {
      s.kind = 'schema';
    } else if (s.depth === 1 && root === 'definitions') {
      s.kind = 'schema';
    } else if (s.depth === 2 && root === 'components') {
      s.kind = 'component';
    }
  });
  // Children of an operation are now shown under "GET /pets"; their container should say so.
  fixContainers(symbols);
  return symbols;
}

// ---- markup ----

function markupRules(html) {
  const tagText = (element, open, c) => {
    const close = kid(element, 'CloseTag');
    const inner = c.state.sliceDoc(open.to, close ? close.from : element.to);
    return inner.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
  };
  return {
    Element: (n, c) => {
      const open = kid(n, 'OpenTag', 'SelfClosingTag');
      const tag = open && kid(open, 'TagName');
      if (!tag) return null;
      const attrs = {};
      for (const a of kids(open, 'Attribute')) {
        const name = kid(a, 'AttributeName');
        const value = kid(a, 'AttributeValue', 'UnquotedAttributeValue');
        if (name) attrs[c.text(name).toLowerCase()] = value ? unquote(c.text(value)) : '';
      }
      let name = c.text(tag);
      let detail = '';
      if (html) {
        if (attrs.id) name += `#${attrs.id}`;
        if (attrs.class) name += attrs.class.split(/\s+/).filter(Boolean).slice(0, 2).map((k) => '.' + k).join('');
        if (/^h[1-6]$/i.test(c.text(tag)) || c.text(tag).toLowerCase() === 'title') detail = tagText(n, open, c);
        else if (attrs.name) detail = attrs.name;
      } else {
        detail = attrs.id ?? attrs.name ?? attrs.key ?? attrs.ref ?? attrs.class ?? '';
        // <artifactId>core</artifactId>: leaf elements show their text.
        if (!detail && !kid(n, 'Element')) detail = tagText(n, open, c);
      }
      return { name, kind: 'element', from: tag.from, to: tag.to, detail };
    },
  };
}

const headingRules = {};
for (let level = 1; level <= 6; level++) {
  headingRules[`ATXHeading${level}`] = (n, c) => ({
    name: c.text(n).replace(/^#+\s*/, '').replace(/\s+#+\s*$/, ''), kind: 'heading', level, from: n.from, to: n.to,
  });
}
for (const level of [1, 2]) {
  headingRules[`SetextHeading${level}`] = (n, c) => ({
    name: c.text(n).split('\n')[0], kind: 'heading', level, from: n.from, to: n.from + c.text(n).split('\n')[0].length,
  });
}

function markdownSymbols(state, out) {
  const tree = parsed(state, out);
  const ctx = { state, text: (n) => state.sliceDoc(n.from, n.to) };
  tree.iterate({
    enter(ref) {
      if (out.full) return false;
      const rule = headingRules[ref.name];
      if (!rule) return ['FencedCode', 'CodeBlock', 'HTMLBlock'].includes(ref.name) ? false : undefined;
      const s = rule(ref.node, ctx);
      out.addLevel(s, s.level);
      return false;
    },
  });
}

// ---------- line-based languages ----------

function eachLine(state, fn) {
  const { doc } = state;
  for (let i = 1; i <= doc.lines; i++) {
    const line = doc.line(i);
    if (fn(line.text, line.from, i, doc) === false) break;
  }
}
const at = (from, text, match, group = 1) => {
  const start = from + match.index + match[0].indexOf(match[group]);
  return { from: start, to: start + match[group].length };
};

function shellSymbols(state, out) {
  const seen = new Set();
  eachLine(state, (text, from) => {
    let m = text.match(/^\s*function\s+([\w:.@+-]+)\s*(\(\s*\))?/) ?? text.match(/^\s*([\w:.@+-]+)\s*\(\s*\)\s*(\{|\(|$)/);
    if (m) return out.addLevel({ name: m[1], kind: 'function', ...at(from, text, m) }, 0);
    m = text.match(/^\s*alias\s+([\w.@+-]+)=/);
    if (m) return out.addLevel({ name: m[1], kind: 'constant', detail: 'alias', ...at(from, text, m) }, 0);
    m = text.match(/^(?:export\s+|readonly\s+|declare\s+(?:-\w+\s+)*|local\s+)?([A-Za-z_]\w*)=(.*)$/);
    if (m && !seen.has(m[1])) {
      seen.add(m[1]);
      out.addLevel({ name: m[1], kind: 'variable', detail: m[2], ...at(from, text, m) }, 0);
    }
    return undefined;
  });
}

function tomlSymbols(state, out) {
  let inTable = false;
  let multiline = false;
  eachLine(state, (text, from) => {
    if (multiline) {
      if ((text.match(/"""|'''/g) ?? []).length % 2 === 1) multiline = false;
      return;
    }
    let m = text.match(/^\s*\[\[\s*([^\]]+?)\s*\]\]/) ?? text.match(/^\s*\[\s*([^\]]+?)\s*\]/);
    if (m) {
      inTable = true;
      out.addLevel({ name: m[1], kind: text.trim().startsWith('[[') ? 'array' : 'object', ...at(from, text, m) }, 0);
      return;
    }
    m = text.match(/^\s*((?:[A-Za-z0-9_-]+|"[^"]*"|'[^']*')(?:\s*\.\s*(?:[A-Za-z0-9_-]+|"[^"]*"|'[^']*'))*)\s*=\s*(.*)$/);
    if (m) {
      out.addLevel({ name: m[1], kind: 'key', detail: m[2].startsWith('"""') || m[2].startsWith("'''") ? '' : m[2], ...at(from, text, m) },
        inTable ? 1 : 0);
      if ((m[2].match(/"""|'''/g) ?? []).length % 2 === 1) multiline = true;
    }
  });
}

function propertiesSymbols(state, out) {
  let inSection = false;
  let continued = false;
  eachLine(state, (text, from) => {
    const wasContinued = continued;
    continued = /(^|[^\\])(\\\\)*\\$/.test(text);
    if (wasContinued) return;
    let m = text.match(/^\s*\[\s*([^\]]+?)\s*\]/);
    if (m) {
      inSection = true;
      out.addLevel({ name: m[1], kind: 'object', ...at(from, text, m) }, 0);
      return;
    }
    m = text.match(/^\s*((?:\\.|[^#!;\s=:\\])(?:\\.|[^=:\s\\])*)\s*[=:\s]\s*(.*)$/);
    if (m && !/^\s*[#!;]/.test(text)) out.addLevel({ name: m[1], kind: 'key', detail: m[2], ...at(from, text, m) }, inSection ? 1 : 0);
  });
}

/** Brace depth at the start of each line, skipping strings and comments (enough for Kotlin-like languages). */
function braceDepths(text) {
  const depths = [0];
  let depth = 0;
  let i = 0;
  const n = text.length;
  while (i < n) {
    const ch = text[i];
    if (ch === '\n') {
      depths.push(depth);
      i++;
    } else if (ch === '/' && text[i + 1] === '/') {
      while (i < n && text[i] !== '\n') i++;
    } else if (ch === '/' && text[i + 1] === '*') {
      i += 2;
      while (i < n && !(text[i] === '*' && text[i + 1] === '/')) {
        if (text[i] === '\n') depths.push(depth);
        i++;
      }
      i += 2;
    } else if (ch === '"' && text.startsWith('"""', i)) {
      i += 3;
      while (i < n && !text.startsWith('"""', i)) {
        if (text[i] === '\n') depths.push(depth);
        i++;
      }
      i += 3;
    } else if (ch === '"' || ch === "'") {
      i++;
      while (i < n && text[i] !== ch && text[i] !== '\n') i += text[i] === '\\' ? 2 : 1;
      i++;
    } else {
      if (ch === '{') depth++;
      else if (ch === '}') depth = Math.max(0, depth - 1);
      i++;
    }
  }
  return depths;
}

const KOTLIN_MODIFIERS = '(?:(?:public|private|protected|internal|open|final|abstract|sealed|data|annotation|inner|override|suspend|inline|noinline|crossinline|operator|infix|tailrec|external|const|lateinit|value|expect|actual|enum|companion|fun(?=\\s+interface))\\s+)*';
const KOTLIN_DECL = new RegExp(`^\\s*(?:@[\\w.]+(?:\\([^)]*\\))?\\s+)*${KOTLIN_MODIFIERS}(class|interface|object|fun|val|var|typealias)\\b\\s*(?:<[^>]*>\\s*)?((?:[\\w.]+\\.)?(?:\`[^\`]+\`|\\w+))?`);

function kotlinSymbols(state, out) {
  const depths = braceDepths(state.doc.toString());
  const open = [];
  eachLine(state, (text, from, number) => {
    const m = text.match(KOTLIN_DECL);
    if (!m) return;
    const depth = depths[number - 1] ?? 0;
    while (open.length && open[open.length - 1].depth >= depth) open.pop();
    const keyword = m[1];
    const insideFunction = open.some((o) => o.keyword === 'fun');
    if ((keyword === 'val' || keyword === 'var') && insideFunction) return;
    const modifiers = text.slice(0, m.index + m[0].indexOf(keyword));
    let name = m[2];
    if (!name && keyword === 'object' && /\bcompanion\b/.test(modifiers)) name = 'companion object';
    if (!name) return;
    const receiver = name.includes('.') && keyword === 'fun' ? name.slice(0, name.lastIndexOf('.')) : '';
    if (receiver) name = name.slice(receiver.length + 1);
    const kind = keyword === 'fun' ? (open.some((o) => o.keyword !== 'fun') ? 'method' : 'function')
      : keyword === 'val' ? (/\bconst\b/.test(modifiers) ? 'constant' : open.length ? 'property' : 'constant')
      : keyword === 'var' ? (open.length ? 'property' : 'variable')
      : keyword === 'typealias' ? 'type'
      : keyword === 'interface' ? 'interface'
      : /\benum\b/.test(modifiers) ? 'enum'
      : keyword === 'object' ? 'module' : 'class';
    const named = text.indexOf(name, m.index + m[0].indexOf(keyword));
    const index = named >= 0 ? named : text.indexOf(name.split(' ')[0]);
    out.addLevel({ name, kind, from: from + Math.max(index, 0), to: from + Math.max(index, 0) + name.length,
                   detail: [receiver && `${receiver}.`, /\bdata\b/.test(modifiers) && 'data', /\bsealed\b/.test(modifiers) && 'sealed',
                            /\bsuspend\b/.test(modifiers) && 'suspend'].filter(Boolean).join(' ') }, depth);
    open.push({ depth, keyword });
  });
}

// SQL: one symbol per statement; CREATE statements are named after what they create (tables list their columns).
const SQL_CREATE = /^CREATE\s+(?:OR\s+REPLACE\s+)?(?:(?:GLOBAL|LOCAL|TEMP|TEMPORARY|UNLOGGED|MATERIALIZED|UNIQUE|RECURSIVE|VIRTUAL|DEFINER\s*=\s*\S+)\s+)*(TABLE|VIEW|INDEX|FUNCTION|PROCEDURE|TRIGGER|SCHEMA|DATABASE|TYPE|SEQUENCE|EXTENSION|DOMAIN|POLICY|ROLE|EVENT|PACKAGE|SYNONYM)\s+(?:IF\s+NOT\s+EXISTS\s+)?((?:[`"[]?[\w$]+[`"\]]?\s*\.\s*)*[`"[]?[\w$]+[`"\]]?)/i;
const SQL_KINDS = { TABLE: 'table', VIEW: 'view', INDEX: 'index', FUNCTION: 'function', PROCEDURE: 'function', TRIGGER: 'event',
                    SCHEMA: 'namespace', DATABASE: 'namespace', TYPE: 'type', DOMAIN: 'type', SEQUENCE: 'constant',
                    EXTENSION: 'module', PACKAGE: 'module' };
const SQL_NOT_COLUMN = /^(CONSTRAINT|PRIMARY|FOREIGN|UNIQUE|CHECK|INDEX|KEY|FULLTEXT|SPATIAL|EXCLUDE|PERIOD|LIKE)\b/i;
const sqlIdent = (text) => text.replace(/[`"[\]]/g, '').replace(/\s*\.\s*/g, '.');

function sqlStatements(text) {
  const statements = [];
  let start = -1;
  let comment = '';
  let lastComment = '';
  for (let i = 0, n = text.length; i < n; i++) {
    const ch = text[i];
    if (ch === '-' && text[i + 1] === '-') {
      const end = text.indexOf('\n', i);
      comment = text.slice(i + 2, end < 0 ? n : end).trim();
      if (start < 0) lastComment = comment;
      i = end < 0 ? n : end;
      continue;
    }
    if (ch === '/' && text[i + 1] === '*') {
      const end = text.indexOf('*/', i + 2);
      i = end < 0 ? n : end + 1;
      continue;
    }
    if (start < 0) {
      if (/\s/.test(ch)) continue;
      if (ch === ';') continue;
      start = i;
    }
    if (ch === "'" || ch === '"' || ch === '`') {
      let j = i + 1;
      while (j < n && !(text[j] === ch && text[j + 1] !== ch)) j += text[j] === ch ? 2 : 1;
      i = j;
    } else if (ch === '$') {
      const tag = text.slice(i).match(/^\$[\w]*\$/)?.[0];
      if (tag) {
        const end = text.indexOf(tag, i + tag.length);
        i = end < 0 ? n : end + tag.length - 1;
      }
    } else if (ch === ';') {
      statements.push({ from: start, to: i, comment: lastComment });
      start = -1;
      lastComment = '';
    }
  }
  if (start >= 0) statements.push({ from: start, to: text.length, comment: lastComment });
  return statements;
}

function sqlSymbols(state, out) {
  const text = state.doc.toString();
  for (const st of sqlStatements(text)) {
    if (out.full) break;
    const body = text.slice(st.from, st.to);
    const head = body.slice(0, 4000);
    const firstLine = head.split('\n')[0].trim();
    const create = head.match(SQL_CREATE);
    // sqlc-style "-- name: GetUser :one" names the query that follows.
    const named = st.comment.match(/^name:\s*(\S+)\s*(:\w+)?/i);
    if (create) {
      const type = create[1].toUpperCase();
      const nameAt = st.from + create.index + create[0].length - create[2].length;
      out.addLevel({ name: sqlIdent(create[2]), kind: SQL_KINDS[type] ?? 'statement', detail: create[1].toLowerCase(),
                     from: nameAt, to: nameAt + create[2].length }, 0);
      if (type === 'TABLE') sqlColumns(body, st.from, create.index + create[0].length, out);
    } else {
      const verb = firstLine.split(/\s+/)[0].toUpperCase();
      out.addLevel({ name: named ? named[1] : firstLine, kind: /^(SELECT|WITH|VALUES|SHOW|EXPLAIN|DESCRIBE)$/.test(verb) ? 'query' : 'statement',
                     detail: named ? firstLine : '', from: st.from, to: st.from + firstLine.length }, 0);
    }
    // Common table expressions: WITH a AS (…), b AS (…)
    const ctes = /(?:\bWITH(?:\s+RECURSIVE)?|\)\s*,)\s*([A-Za-z_][\w$]*)\s*(?:\([^)]*\)\s*)?AS\s*(?:NOT\s+)?(?:MATERIALIZED\s*)?\(/gi;
    for (const m of head.matchAll(ctes)) {
      const from = st.from + m.index + m[0].indexOf(m[1]);
      out.addLevel({ name: m[1], kind: 'cte', from, to: from + m[1].length }, 1);
    }
  }
}

function sqlColumns(body, offset, after, out) {
  const open = body.indexOf('(', after);
  if (open < 0) return;
  let depth = 0;
  let partStart = open + 1;
  for (let i = open; i < body.length; i++) {
    const ch = body[i];
    if (ch === "'" || ch === '"' || ch === '`') {
      const end = body.indexOf(ch, i + 1);
      i = end < 0 ? body.length : end;
    } else if (ch === '(') {
      depth++;
    } else if (ch === ')' || (ch === ',' && depth === 1)) {
      if (depth === 1) {
        const part = body.slice(partStart, i);
        const lead = part.length - part.trimStart().length;
        const m = part.trimStart().match(/^([`"[]?[\w$]+[`"\]]?)\s+(.*)$/s);
        if (m && !SQL_NOT_COLUMN.test(part.trimStart())) {
          const from = offset + partStart + lead;
          out.addLevel({ name: sqlIdent(m[1]), kind: 'field', detail: m[2].split(/[\n,]/)[0], from, to: from + m[1].length }, 1);
        }
        partStart = i + 1;
      }
      if (ch === ')' && --depth === 0) break;
    }
  }
}

function httpSymbols(state, out) {
  let title = '';
  let named = '';
  eachLine(state, (text, from) => {
    let m = text.match(/^###\s*(.*)$/);
    if (m) {
      title = m[1].trim();
      named = '';
      return;
    }
    m = text.match(/^\s*(?:#|\/\/)\s*@name\s+(\S+)/);
    if (m) {
      named = m[1];
      return;
    }
    m = text.match(/^@([\w.-]+)\s*=\s*(.*)$/);
    if (m) {
      out.addLevel({ name: `@${m[1]}`, kind: 'variable', detail: m[2], ...at(from, text, m) }, 0);
      return;
    }
    m = text.match(/^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|TRACE|CONNECT)\s+(\S+)/);
    if (m) {
      const request = `${m[1]} ${m[2]}`;
      const name = named || title;
      out.addLevel({ name: name || request, kind: 'request', detail: name ? request : '', from: from + m.index, to: from + m[0].length }, 0);
      title = '';
      named = '';
    }
  });
}

function tableSymbols(state, out, delimiter) {
  if (state.doc.lines < 1) return;
  const header = state.doc.line(1);
  const sep = delimiter ?? detectDelimiter(header.text) ?? ',';
  let start = 0, quoted = false, column = 0;
  const text = header.text;
  const emit = (end) => {
    const raw = text.slice(start, end);
    const lead = raw.length - raw.trimStart().length;
    const name = unquote(raw.trim()) || `Column ${column + 1}`;
    out.addLevel({ name, kind: 'column', detail: `column ${column + 1}`, from: header.from + start + lead, to: header.from + start + lead + raw.trim().length }, 0);
    column++;
  };
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '"') quoted = !quoted;
    else if (text[i] === sep && !quoted) {
      emit(i);
      start = i + 1;
    }
  }
  emit(text.length);
}

// Plain text: whatever reads like a heading — "# Title", underlined lines, "1.2 Section", ALL CAPS, "Label:".
function textSymbols(state, out) {
  eachLine(state, (text, from, number, doc) => {
    const trimmed = text.trim();
    if (!trimmed || trimmed.length > 100) return;
    let m = text.match(/^(#{1,6})\s+(\S.*?)\s*#*\s*$/);
    if (m) return out.addLevel({ name: m[2], kind: 'heading', ...at(from, text, m, 2) }, m[1].length);
    const next = number < doc.lines ? doc.line(number + 1).text : '';
    if (/^\s*={3,}\s*$/.test(next) && !/^[=-]+$/.test(trimmed)) return out.addLevel({ name: trimmed, kind: 'heading', from, to: from + text.length }, 1);
    if (/^\s*-{3,}\s*$/.test(next) && !/^[=-]+$/.test(trimmed) && !/^[-*+]\s/.test(trimmed)) {
      return out.addLevel({ name: trimmed, kind: 'heading', from, to: from + text.length }, 2);
    }
    m = text.match(/^(\d+(?:\.\d+)*)[.)]?\s+([A-Z].{0,68})$/);
    if (m && !/[.;,]$/.test(m[2])) {
      return out.addLevel({ name: trimmed, kind: 'section', from, to: from + text.length }, m[1].split('.').length + 1);
    }
    if (/^[A-Z0-9][A-Z0-9 &/\-:,'()]{2,59}$/.test(trimmed) && (trimmed.match(/[A-Z]/g) ?? []).length >= 3) {
      return out.addLevel({ name: trimmed.replace(/:$/, ''), kind: 'heading', from, to: from + text.length }, 1);
    }
    m = text.match(/^([A-Za-z][^:]{1,50}):\s*$/);
    if (m) return out.addLevel({ name: m[1], kind: 'section', ...at(from, text, m) }, 3);
    return undefined;
  });
}

// ---------- entry point ----------

const treeLanguages = {
  javascript: jsRules,
  typescript: jsRules,
  java: javaRules,
  python: pythonRules,
  go: goRules,
  rust: rustRules,
  cpp: cppRules,
  css: cssRules,
  xml: markupRules(false),
  // Scripts and styles inside the page get their functions and selectors listed under their element.
  html: { ...jsRules, ...cssRules, ...markupRules(true) },
};

const OPENAPI = /^["']?(?:openapi|swagger)["']?\s*:\s*["']?\d/m;
const OPENAPI_JSON = /"(?:openapi|swagger)"\s*:\s*"\d/;

export function documentSymbols(state, language) {
  const out = new Collector(state);
  let lang = language;
  if (lang === 'openapi') lang = /^\s*[{[]/.test(state.sliceDoc(0, 200)) ? 'json' : 'yaml';
  if (lang === 'json') jsonSymbols(state, out);
  else if (lang === 'yaml') yamlSymbols(state, out);
  else if (treeLanguages[lang]) walk(state, out, treeLanguages[lang]);
  else if (lang === 'markdown') markdownSymbols(state, out);
  else if (lang === 'shell') shellSymbols(state, out);
  else if (lang === 'toml') tomlSymbols(state, out);
  else if (lang === 'properties') propertiesSymbols(state, out);
  else if (lang === 'kotlin') kotlinSymbols(state, out);
  else if (lang === 'sql') sqlSymbols(state, out);
  else if (lang === 'http') httpSymbols(state, out);
  else if (lang === 'csv') tableSymbols(state, out, null);
  else if (lang === 'tsv') tableSymbols(state, out, '\t');
  else textSymbols(state, out);
  let symbols = out.list;
  const head = state.sliceDoc(0, 20_000);
  if (language === 'openapi' || (lang === 'yaml' && OPENAPI.test(head)) || (lang === 'json' && OPENAPI_JSON.test(head))) {
    symbols = openapiOutline(symbols);
  }
  return { symbols, truncated: out.full || out.partial };
}
