import xmlFormat from 'xml-formatter';
import { formatJson } from './jsonfmt.js';

const METHODS = /^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|TRACE|CONNECT)\s+/i;
const CONTINUATION = /^\s+[?&]/;

/**
 * Splits a URL into its base and query parameters, keeping `{{variables}}` and encoding untouched.
 * The fragment (if any) stays attached to the last parameter.
 */
export function splitUrl(url) {
  const q = url.indexOf('?');
  if (q < 0) return { base: url, params: [] };
  let query = url.slice(q + 1);
  let fragment = '';
  const hash = query.indexOf('#');
  if (hash >= 0) {
    fragment = query.slice(hash);
    query = query.slice(0, hash);
  }
  const params = query.split('&').filter((p) => p.length > 0);
  if (fragment && params.length) params[params.length - 1] += fragment;
  return { base: url.slice(0, q), params, fragment: params.length ? '' : fragment };
}

/** `GET base` followed by one indented `?first` / `&next` line per parameter. */
export function structuredRequestLine(method, url, version, indent) {
  const { base, params, fragment } = splitUrl(url);
  const head = `${method} ${base}${params.length ? '' : fragment ?? ''}${version ? ` ${version}` : ''}`;
  return [head, ...params.map((p, i) => `${indent}${i === 0 ? '?' : '&'}${p}`)];
}

function formatBody(lines, contentType, unit) {
  const text = lines.join('\n').trim();
  if (!text) return [];
  const type = (contentType ?? '').toLowerCase();
  const looksJson = /^[[{]/.test(text);
  if (type.includes('json') || (!type && looksJson)) {
    try {
      return formatJson(text, unit).split('\n');
    } catch {
      // Bodies with unquoted {{variables}} aren't valid JSON; leave them as written.
    }
  } else if (type.includes('xml') || (!type && text.startsWith('<?xml'))) {
    try {
      return xmlFormat(text, { indentation: unit, collapseContent: true, lineSeparator: '\n' }).split('\n');
    } catch {}
  }
  return text.split('\n').map((l) => l.replace(/\s+$/, ''));
}

/** Formats one `###` block (without its separator line). */
function formatBlock(lines, unit, bodyUnit) {
  const out = [];
  let i = 0;
  // Preamble: comments and @variables before the request line.
  for (; i < lines.length; i++) {
    const t = lines[i].trim();
    if (!t) {
      if (out.length && out[out.length - 1] !== '') out.push('');
      continue;
    }
    if (t.startsWith('#') || t.startsWith('//')) {
      out.push(t);
      continue;
    }
    const variable = /^@([\w.-]+)\s*=\s*(.*)$/.exec(t);
    if (variable) {
      out.push(`@${variable[1]} = ${variable[2].trim()}`);
      continue;
    }
    break;
  }
  if (i >= lines.length) {
    while (out.length && out[out.length - 1] === '') out.pop();
    return out;
  }

  // Request line plus any continuation lines.
  let requestLine = lines[i].trim();
  i++;
  while (i < lines.length && CONTINUATION.test(lines[i])) {
    requestLine += lines[i].trim();
    i++;
  }
  const methodMatch = METHODS.exec(requestLine);
  const method = methodMatch ? methodMatch[1].toUpperCase() : 'GET';
  let rest = methodMatch ? requestLine.slice(methodMatch[0].length).trim() : requestLine;
  let version = '';
  const versionMatch = /\s+(HTTP\/[\d.]+)$/i.exec(rest);
  if (versionMatch) {
    version = versionMatch[1].toUpperCase();
    rest = rest.slice(0, versionMatch.index).trim();
  }
  const { params } = splitUrl(rest);
  if (params.length) out.push(...structuredRequestLine(method, rest, version, unit));
  else out.push(`${methodMatch ? method : 'GET'} ${rest}${version ? ` ${version}` : ''}`);

  // Headers until the first blank line.
  let contentType = '';
  for (; i < lines.length; i++) {
    const line = lines[i];
    const t = line.trim();
    if (!t) break;
    if (t.startsWith('#') || t.startsWith('//')) {
      out.push(t);
      continue;
    }
    const colon = t.indexOf(':');
    if (colon <= 0) {
      out.push(t);
      continue;
    }
    const name = t.slice(0, colon).trim();
    const value = t.slice(colon + 1).trim();
    if (name.toLowerCase() === 'content-type') contentType = value;
    out.push(`${name}: ${value}`);
  }

  const body = formatBody(lines.slice(i), contentType, bodyUnit);
  if (body.length) out.push('', ...body);
  return out;
}

/**
 * Formats an `.http` file: structured query parameters, tidy headers, pretty JSON/XML bodies.
 * Query continuation lines use at least four spaces so they never read as headers.
 */
export function formatHttp(src, tabSize) {
  const unit = ' '.repeat(Math.max(tabSize, 4));
  const bodyUnit = ' '.repeat(tabSize);
  const lines = src.replace(/\r\n/g, '\n').split('\n');
  const blocks = [];
  let current = { separator: null, lines: [] };
  for (const line of lines) {
    if (line.startsWith('###')) {
      blocks.push(current);
      const title = line.slice(3).trim();
      current = { separator: title ? `### ${title}` : '###', lines: [] };
    } else {
      current.lines.push(line);
    }
  }
  blocks.push(current);

  const out = [];
  for (const block of blocks) {
    const formatted = formatBlock(block.lines, unit, bodyUnit);
    if (block.separator === null && formatted.length === 0) continue;
    if (out.length) out.push('');
    if (block.separator !== null) out.push(block.separator);
    out.push(...formatted);
  }
  let result = out.join('\n');
  if (src.endsWith('\n')) result += '\n';
  return result;
}
