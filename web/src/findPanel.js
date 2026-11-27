import {
  SearchQuery, setSearchQuery, getSearchQuery, findNext, findPrevious, replaceNext, replaceAll,
  selectMatches, closeSearchPanel,
} from '@codemirror/search';
import { EditorSelection } from '@codemirror/state';

// Counting stops here so huge documents with short queries stay responsive.
const COUNT_LIMIT = 9999;

function countMatches(state, query) {
  if (!query.valid) return { total: 0, current: 0 };
  const sel = state.selection.main;
  const cursor = query.getCursor(state);
  let total = 0;
  let current = 0;
  for (let next = cursor.next(); !next.done; next = cursor.next()) {
    total++;
    if (next.value.from === sel.from && next.value.to === sel.to) current = total;
    if (total >= COUNT_LIMIT) break;
  }
  return { total, current };
}

// First match at or after `pos`, wrapping to the top of the document.
function matchFrom(state, query, pos) {
  const after = query.getCursor(state, pos).next();
  if (!after.done) return after.value;
  const first = query.getCursor(state).next();
  return first.done ? null : first.value;
}

const el = (tag, attrs = {}, ...children) => {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else if (v === true) node.setAttribute(k, '');
    else if (v !== false && v != null) node.setAttribute(k, v);
  }
  node.append(...children);
  return node;
};

/// Find/replace panel that searches as you type and shows "n of m" next to the field.
export function createFindPanel(view) {
  let query = getSearchQuery(view.state);
  // Where incremental search starts from; any selection change other than typing in the field moves it.
  let origin = view.state.selection.main.from;

  const field = el('input', {
    class: 'cm-textfield', name: 'search', placeholder: 'Find', 'aria-label': 'Find',
    'main-field': true, value: query.search, autocomplete: 'off', spellcheck: 'false',
    oninput: () => commit(true), onkeydown: keydown,
  });
  const replaceField = el('input', {
    class: 'cm-textfield', name: 'replace', placeholder: 'Replace', 'aria-label': 'Replace',
    value: query.replace, autocomplete: 'off', spellcheck: 'false', oninput: () => commit(false), onkeydown: keydown,
  });
  const check = (name, label, checked) => {
    const box = el('input', { type: 'checkbox', name, checked, onchange: () => commit(true) });
    return [box, el('label', {}, box, label)];
  };
  const [caseBox, caseLabel] = check('case', 'match case', query.caseSensitive);
  const [reBox, reLabel] = check('re', 'regexp', query.regexp);
  const [wordBox, wordLabel] = check('word', 'by word', query.wholeWord);
  const count = el('span', { class: 'cm-search-count', 'aria-live': 'polite' });
  const button = (name, label, run, title) =>
    el('button', { class: 'cm-button', name, type: 'button', title, onclick: () => { run(view); refresh(); } }, label);

  const dom = el('div', { class: 'cm-search cm-find', onkeydown: (e) => { if (e.key === 'Escape') { e.preventDefault(); closeSearchPanel(view); view.focus(); } } },
    field, count,
    button('prev', '↑', findPrevious, 'Previous match (⇧↩)'),
    button('next', '↓', findNext, 'Next match (↩)'),
    button('select', 'all', selectMatches, 'Select all matches (⌥↩)'),
    caseLabel, reLabel, wordLabel,
    el('br'),
    replaceField,
    button('replace', 'replace', replaceNext),
    button('replaceAll', 'replace all', replaceAll),
    el('button', { name: 'close', type: 'button', 'aria-label': 'Close', onclick: () => { closeSearchPanel(view); view.focus(); } }, '×'),
  );

  function keydown(e) {
    if (e.key !== 'Enter') return;
    e.preventDefault();
    if (e.target === replaceField) replaceNext(view);
    else if (e.altKey) selectMatches(view);
    else (e.shiftKey ? findPrevious : findNext)(view);
    refresh();
  }

  function commit(jump) {
    const next = new SearchQuery({
      search: field.value, replace: replaceField.value,
      caseSensitive: caseBox.checked, regexp: reBox.checked, wholeWord: wordBox.checked,
    });
    if (!next.eq(query)) {
      query = next;
      view.dispatch({ effects: setSearchQuery.of(query) });
    }
    if (jump && query.valid) {
      const match = matchFrom(view.state, query, origin);
      if (match) {
        view.dispatch({ selection: EditorSelection.single(match.from, match.to), scrollIntoView: true, userEvent: 'select.search.incremental' });
      }
    }
    refresh();
  }

  function refresh() {
    field.classList.toggle('cm-search-invalid', !!field.value && !query.valid);
    if (!field.value) { count.textContent = ''; count.className = 'cm-search-count'; return; }
    if (!query.valid) { count.textContent = 'invalid'; count.className = 'cm-search-count none'; return; }
    const { total, current } = countMatches(view.state, query);
    const more = total >= COUNT_LIMIT ? '+' : '';
    count.textContent = total === 0 ? 'No results' : current ? `${current} of ${total}${more}` : `${total}${more} found`;
    count.className = total === 0 ? 'cm-search-count none' : 'cm-search-count';
  }

  return {
    dom,
    top: true,
    mount() { field.select(); refresh(); },
    update(update) {
      for (const tr of update.transactions) {
        for (const e of tr.effects) {
          if (e.is(setSearchQuery) && !e.value.eq(query)) {
            query = e.value;
            field.value = query.search;
            replaceField.value = query.replace;
            caseBox.checked = query.caseSensitive;
            reBox.checked = query.regexp;
            wordBox.checked = query.wholeWord;
          }
        }
        if (tr.selection && !tr.isUserEvent('select.search.incremental')) origin = tr.newSelection.main.from;
      }
      if (update.docChanged || update.selectionSet || update.transactions.some((tr) => tr.effects.length)) refresh();
    },
  };
}
