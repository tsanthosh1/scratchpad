import * as prettier from 'prettier/standalone';
import * as prettierBabel from 'prettier/plugins/babel';
import * as prettierEstree from 'prettier/plugins/estree';
import * as prettierHtml from 'prettier/plugins/html';
import * as prettierPostcss from 'prettier/plugins/postcss';
import * as prettierMarkdown from 'prettier/plugins/markdown';
import * as prettierYaml from 'prettier/plugins/yaml';
import * as prettierTypescript from 'prettier/plugins/typescript';
import prettierJava from 'prettier-plugin-java';
import xmlFormat from 'xml-formatter';
import { format as formatSql } from 'sql-formatter';
import { formatJson, JsonError } from './jsonfmt.js';
import { formatHttp } from './httpfmt.js';

const web = [prettierBabel, prettierEstree, prettierPostcss];
const prettierSetups = {
  javascript: { parser: 'babel', plugins: web },
  typescript: { parser: 'typescript', plugins: [prettierTypescript, prettierEstree] },
  html: { parser: 'html', plugins: [prettierHtml, ...web] },
  css: { parser: 'scss', plugins: [prettierPostcss] },
  markdown: { parser: 'markdown', plugins: [prettierMarkdown, prettierHtml, prettierYaml, ...web] },
  yaml: { parser: 'yaml', plugins: [prettierYaml] },
  java: { parser: 'java', plugins: [prettierJava] },
};

export class FormatError extends Error {
  constructor(message, line, column) {
    super(message);
    this.line = line;
    this.column = column;
  }
}

/** Returns the formatted text or throws a FormatError (with a 1-based position when known). */
export async function formatSource(language, src, { tabSize, compact }) {
  const unit = ' '.repeat(tabSize);
  try {
    if (language === 'json') return formatJson(src, compact ? null : unit);
    if (language === 'xml') {
      return compact
        ? xmlFormat.minify(src, { collapseContent: true })
        : xmlFormat(src, { indentation: unit, collapseContent: true, lineSeparator: '\n' });
    }
    if (language === 'http') return formatHttp(src, tabSize);
    if (language === 'sql') return formatSql(src, { language: 'sql', tabWidth: tabSize, keywordCase: 'upper' });
    const setup = prettierSetups[language];
    if (!setup) throw new FormatError(`No formatter for ${language}`);
    // Java conventionally uses 4-space indents regardless of the editor setting.
    const tabWidth = language === 'java' ? Math.max(tabSize, 4) : tabSize;
    let out = await prettier.format(src, { ...setup, tabWidth, printWidth: language === 'markdown' ? 80 : 120 });
    if (!src.endsWith('\n')) out = out.replace(/\n$/, '');
    return out;
  } catch (e) {
    if (e instanceof FormatError) throw e;
    if (e instanceof JsonError) throw Object.assign(new FormatError(e.message), { offset: e.pos });
    const raw = String(e?.message || e);
    let loc = e?.loc?.start;
    const javaLoc = /line: (\d+), column: (\d+)/.exec(raw);
    if (!loc && javaLoc) loc = { line: Number(javaLoc[1]), column: Number(javaLoc[2]) };
    const detail = javaLoc ? 'Syntax error' : raw.split('\n')[0].replace(/\s*\(\d+:\d+\)$/, '');
    throw new FormatError(detail, loc?.line, loc?.column);
  }
}
