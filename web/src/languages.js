import { LanguageDescription, LanguageSupport, StreamLanguage } from '@codemirror/language';
import { json } from '@codemirror/lang-json';
import { xml } from '@codemirror/lang-xml';
import { html } from '@codemirror/lang-html';
import { javascript } from '@codemirror/lang-javascript';
import { java } from '@codemirror/lang-java';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { css } from '@codemirror/lang-css';
import { sql } from '@codemirror/lang-sql';
import { python } from '@codemirror/lang-python';
import { yaml } from '@codemirror/lang-yaml';
import { go } from '@codemirror/lang-go';
import { rust } from '@codemirror/lang-rust';
import { cpp } from '@codemirror/lang-cpp';
import { shell } from '@codemirror/legacy-modes/mode/shell';
import { toml } from '@codemirror/legacy-modes/mode/toml';
import { properties } from '@codemirror/legacy-modes/mode/properties';
import { kotlin } from '@codemirror/legacy-modes/mode/clike';

import { http } from './http.js';
import { csv } from './csv.js';

const legacy = (mode) => () => new LanguageSupport(StreamLanguage.define(mode));

// Keys match the Swift `Language` raw values.
const base = {
  json: () => json(),
  xml: () => xml(),
  html: () => html(),
  javascript: () => javascript({ jsx: true }),
  typescript: () => javascript({ typescript: true }),
  java: () => java(),
  python: () => python(),
  shell: legacy(shell),
  css: () => css(),
  sql: () => sql(),
  yaml: () => yaml(),
  // OpenAPI specs are YAML or JSON; YAML highlighting covers both (JSON is valid YAML).
  openapi: () => yaml(),
  toml: legacy(toml),
  properties: legacy(properties),
  kotlin: legacy(kotlin),
  go: () => go(),
  rust: () => rust(),
  cpp: () => cpp(),
  text: () => [],
  csv: () => csv(),
  tsv: () => csv('\t'),
};

const aliases = {
  javascript: ['js', 'jsx', 'node'], typescript: ['ts', 'tsx'], python: ['py'], shell: ['sh', 'bash', 'zsh', 'console'],
  yaml: ['yml'], cpp: ['c', 'c++', 'h'], rust: ['rs'], kotlin: ['kt'], markdown: ['md'], properties: ['ini', 'env'],
};

// Fenced code blocks inside Markdown get the same highlighting as standalone scratches.
const codeLanguages = Object.entries(base)
  .filter(([name]) => !['text', 'csv', 'tsv', 'openapi'].includes(name))
  .map(([name, make]) => LanguageDescription.of({ name, alias: aliases[name] ?? [], support: make() }));

export const languages = {
  ...base,
  markdown: () => markdown({ base: markdownLanguage, codeLanguages }),
  http,
};
