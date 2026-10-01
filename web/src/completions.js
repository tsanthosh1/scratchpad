import { EditorState } from '@codemirror/state';
import { completeAnyWord, completeFromList, ifNotIn, snippetCompletion as snip } from '@codemirror/autocomplete';
import { scopeCompletionSource } from '@codemirror/lang-javascript';
import { syntaxTree } from '@codemirror/language';

// Extra completion sources per language, on top of what the language packages already provide
// (JS/TS locals + keywords, Python, CSS, HTML, SQL, Go).

const keywords = (list, type = 'keyword') => list.split(/\s+/).filter(Boolean).map((label) => ({ label, type }));

// Inside strings and comments only plain word completion makes sense.
const NOT_CODE = ['String', 'StringLiteral', 'TemplateString', 'Comment', 'LineComment', 'BlockComment', 'TextBlock',
  'CharLiteral', 'RawString', 'string', 'comment'];
// Snippets and keywords never follow a member access such as `obj.`.
const notAfterDot = (source) => (context) => {
  const word = context.matchBefore(/[\w$]*$/);
  const from = word ? word.from : context.pos;
  return from > 0 && context.state.sliceDoc(from - 1, from) === '.' ? null : source(context);
};
const inCode = (source) => ifNotIn(NOT_CODE, notAfterDot(source));

const javaSnippets = [
  snip('public static void main(String[] args) {\n\t${}\n}', { label: 'psvm', detail: 'main method', type: 'snippet' }),
  snip('public static void main(String[] args) {\n\t${}\n}', { label: 'main', detail: 'main method', type: 'snippet' }),
  snip('System.out.println(${});', { label: 'sout', detail: 'println', type: 'snippet' }),
  snip('System.out.printf("${}%n");', { label: 'souf', detail: 'printf', type: 'snippet' }),
  snip('System.err.println(${});', { label: 'serr', detail: 'stderr println', type: 'snippet' }),
  snip('for (int ${i} = 0; ${i} < ${n}; ${i}++) {\n\t${}\n}', { label: 'fori', detail: 'indexed for', type: 'snippet' }),
  snip('for (var ${item} : ${items}) {\n\t${}\n}', { label: 'iter', detail: 'for-each', type: 'snippet' }),
  snip('if (${x} == null) {\n\t${}\n}', { label: 'ifn', detail: 'if null', type: 'snippet' }),
  snip('if (${x} != null) {\n\t${}\n}', { label: 'inn', detail: 'if not null', type: 'snippet' }),
  snip('try {\n\t${}\n} catch (${Exception} e) {\n\tthrow new RuntimeException(e);\n}', { label: 'try', detail: 'try/catch', type: 'snippet' }),
  snip('record ${Name}(${}) {}', { label: 'record', detail: 'record', type: 'snippet' }),
];
const javaWords = keywords(`abstract assert boolean break byte case catch char class continue default do double else enum
  extends final finally float for if implements import instanceof int interface long native new package private protected
  public return short static strictfp super switch synchronized this throw throws transient try var void volatile while
  record sealed permits yield true false null`)
  .concat(keywords(`String Integer Long Double Boolean Character Object Math List ArrayList Map HashMap LinkedHashMap
    TreeMap Set HashSet TreeSet Optional Stream Collectors Arrays Collections StringBuilder Objects Iterator Iterable
    Comparator Function Supplier Consumer Predicate Runnable Thread Exception RuntimeException IllegalArgumentException
    IllegalStateException LocalDate LocalDateTime Instant Duration UUID Pattern Matcher Files Path Paths System`, 'class'));

const jsSnippets = [
  snip('console.log(${});', { label: 'log', detail: 'console.log', type: 'snippet' }),
  snip('console.log(${});', { label: 'clg', detail: 'console.log', type: 'snippet' }),
  snip('const ${name} = require("${module}");', { label: 'req', detail: 'require', type: 'snippet' }),
  snip('import ${name} from "${module}";', { label: 'imp', detail: 'import default', type: 'snippet' }),
  snip('const ${name} = async (${}) => {\n\t${}\n};', { label: 'afn', detail: 'async arrow function', type: 'snippet' }),
  snip('for (const ${item} of ${items}) {\n\t${}\n}', { label: 'forof', detail: 'for…of', type: 'snippet' }),
  snip('setTimeout(() => {\n\t${}\n}, ${1000});', { label: 'timeout', detail: 'setTimeout', type: 'snippet' }),
  snip('JSON.stringify(${}, null, 2)', { label: 'jsonpp', detail: 'pretty JSON', type: 'snippet' }),
];

const pythonSnippets = [
  snip('if __name__ == "__main__":\n\t${main()}', { label: 'ifmain', detail: '__main__ guard', type: 'snippet' }),
  snip('def ${name}(${}):\n\t${pass}', { label: 'def', detail: 'function', type: 'snippet' }),
  snip('for ${i} in range(${n}):\n\t${}', { label: 'fori', detail: 'for range', type: 'snippet' }),
  snip('print(f"${}")', { label: 'pf', detail: 'print f-string', type: 'snippet' }),
];

const kotlinWords = keywords(`as break class continue do else false for fun if in interface is null object package return
  super this throw true try typealias typeof val var when while by catch constructor data enum finally get import init
  inline internal lateinit open override private protected public sealed set suspend companion`)
  .concat([snip('fun main() {\n\t${}\n}', { label: 'main', detail: 'main function', type: 'snippet' }),
    snip('println(${})', { label: 'sout', detail: 'println', type: 'snippet' })]);

const rustWords = keywords(`as async await break const continue crate dyn else enum extern false fn for if impl in let loop
  match mod move mut pub ref return self Self static struct super trait true type unsafe use where while
  String Vec Option Some None Result Ok Err Box HashMap`)
  .concat([snip('fn main() {\n\t${}\n}', { label: 'main', detail: 'main function', type: 'snippet' }),
    snip('println!("{}", ${});', { label: 'pl', detail: 'println!', type: 'snippet' })]);

const cppWords = keywords(`auto bool break case catch char class const constexpr continue default delete do double else
  enum explicit extern false float for friend if inline int long namespace new nullptr operator private protected public
  return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using
  virtual void volatile while include define std string vector map unordered_map cout cin endl`)
  .concat([snip('int main() {\n\t${}\n\treturn 0;\n}', { label: 'main', detail: 'main function', type: 'snippet' }),
    snip('std::cout << ${} << std::endl;', { label: 'cout', detail: 'print line', type: 'snippet' })]);

const shellWords = keywords(`if then else elif fi case esac for while until do done in function select return exit local
  export readonly shift echo printf read cd pwd ls cat grep sed awk find xargs sort uniq head tail wc curl jq test set
  unset source eval trap`)
  .concat([snip('if [[ ${} ]]; then\n\t${}\nfi', { label: 'if', detail: 'if block', type: 'snippet' }),
    snip('for ${f} in ${}; do\n\t${}\ndone', { label: 'for', detail: 'for loop', type: 'snippet' })]);

// HTTP scratches: methods on request lines, header names and common values.
const METHODS = 'GET POST PUT PATCH DELETE HEAD OPTIONS';
const HEADERS = `Accept Accept-Encoding Accept-Language Authorization Cache-Control Connection Content-Length
  Content-Type Cookie Host If-Match If-None-Match Origin Referer User-Agent X-Request-Id X-Api-Key X-Forwarded-For`;
const HEADER_VALUES = {
  'content-type': ['application/json', 'application/x-www-form-urlencoded', 'multipart/form-data', 'text/plain',
    'application/xml', 'text/html'],
  accept: ['application/json', '*/*', 'text/html', 'application/xml'],
  authorization: ['Bearer ', 'Basic '],
  'cache-control': ['no-cache', 'no-store', 'max-age=0'],
  'accept-encoding': ['gzip, deflate, br', 'identity'],
  connection: ['keep-alive', 'close'],
};

function httpSource(context) {
  const line = context.state.doc.lineAt(context.pos);
  const before = line.text.slice(0, context.pos - line.from);
  const valueMatch = /^([A-Za-z0-9-]+):\s*(.*)$/.exec(before);
  if (valueMatch) {
    const values = HEADER_VALUES[valueMatch[1].toLowerCase()];
    if (!values) return null;
    return { from: context.pos - valueMatch[2].length, options: values.map((label) => ({ label, type: 'constant' })), validFor: /^[\w/*.+ =-]*$/ };
  }
  const word = context.matchBefore(/^[A-Za-z-]*$/);
  if (!word || (word.from === word.to && !context.explicit)) return null;
  // Header names only after a request line and before the first blank line of the block.
  let inHeaders = false;
  for (let n = line.number - 1; n >= 1; n--) {
    const text = context.state.doc.line(n).text;
    if (!text.trim() || text.startsWith('###')) break;
    if (/^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|TRACE|CONNECT)\s/.test(text)) { inHeaders = true; break; }
  }
  const options = inHeaders
    ? keywords(HEADERS, 'property').map((o) => ({ ...o, apply: o.label + ': ' }))
    : keywords(METHODS, 'keyword').map((o) => ({ ...o, apply: o.label + ' ' }))
      .concat([snip('### ${Request name}\n${GET} ${https://}', { label: '###', detail: 'new request', type: 'snippet' })]);
  return { from: word.from, options, validFor: /^[A-Za-z-]*$/ };
}

// Member completion on JS globals (console., Math., JSON., Object., …), skipped inside strings/comments.
const jsGlobals = scopeCompletionSource(globalThis);
function jsMembers(context) {
  const node = syntaxTree(context.state).resolveInner(context.pos, -1);
  if (NOT_CODE.includes(node.name)) return null;
  return jsGlobals(context);
}

const extras = {
  javascript: [inCode(completeFromList(jsSnippets)), jsMembers],
  typescript: [inCode(completeFromList(jsSnippets)), jsMembers],
  java: [inCode(completeFromList([...javaSnippets, ...javaWords]))],
  python: [inCode(completeFromList(pythonSnippets))],
  kotlin: [notAfterDot(completeFromList(kotlinWords))],
  rust: [inCode(completeFromList(rustWords))],
  cpp: [inCode(completeFromList(cppWords))],
  shell: [notAfterDot(completeFromList(shellWords))],
  http: [httpSource],
};

// Languages whose packages already complete local names don't also need document words.
const hasLocalCompletion = new Set(['javascript', 'typescript', 'python', 'css', 'html', 'go']);

/** Language-data extension adding this language's completion sources (plus document words). */
export function completionSources(language, support) {
  const sources = [...(extras[language] ?? [])];
  if (!hasLocalCompletion.has(language)) sources.push(completeAnyWord);
  if (!support?.language) return EditorState.languageData.of(() => sources.map((autocomplete) => ({ autocomplete })));
  return sources.map((autocomplete) => support.language.data.of({ autocomplete }));
}
