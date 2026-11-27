// OpenAPI viewers (Swagger UI, Scalar, Kong spec renderer) for the preview iframe (viewer.html) and for exported pages.
// In the preview the libraries are loaded from the app bundle on demand; exported pages inline them before this file.
// Plain script, not bundled: it is copied as is, and inlined into exports.
(function () {
  const LIBS = {
    swagger: { global: 'SwaggerUIBundle', scripts: ['swagger-ui-bundle.js'], styles: ['swagger-ui.css'] },
    scalar: { global: 'Scalar', scripts: ['scalar.js'], styles: [] },
    kong: { global: 'KongSpecRenderer', scripts: ['kong-spec-renderer.js'], styles: ['kong-spec-renderer.css'] },
  };
  const dark = window.matchMedia('(prefers-color-scheme: dark)');
  const root = () => document.getElementById('viewer');
  let current = null; // { viewer, instance, options }
  let latest = null;

  const load = (tag, attrs) => new Promise((resolve, reject) => {
    const el = document.createElement(tag);
    Object.assign(el, attrs);
    el.onload = resolve;
    el.onerror = () => reject(new Error(`${attrs.src || attrs.href} could not be loaded`));
    document.head.appendChild(el);
  });
  async function ensure(viewer) {
    const lib = LIBS[viewer];
    if (window[lib.global]) return;
    await Promise.all([
      ...lib.styles.map((href) => load('link', { rel: 'stylesheet', href })),
      ...lib.scripts.map((src) => load('script', { src })),
    ]);
  }

  function status(text) {
    let el = document.querySelector('.viewer-status');
    if (!text) return el?.remove();
    if (!el) {
      el = document.createElement('div');
      el.className = 'viewer-status';
      document.body.prepend(el);
    }
    el.textContent = text;
  }

  function theme(isDark) {
    document.documentElement.classList.toggle('dark-mode', isDark);
    document.documentElement.dataset.theme = isDark ? 'dark' : 'light';
  }

  const scalarConfig = (o, isDark) => ({
    content: o.spec,
    darkMode: isDark,
    forceDarkModeState: isDark ? 'dark' : 'light',
    hideDarkModeToggle: !o.standalone,
    withDefaultFonts: false,
    showDeveloperTools: 'never',
    defaultOpenAllTags: !!o.snapshot,
    expandAllResponses: !!o.snapshot,
    expandAllModelSections: !!o.snapshot,
    documentDownloadType: o.standalone ? 'both' : 'none',
    mcp: { disabled: true },
    agent: { disabled: true },
  });

  /**
   * options: { viewer: 'swagger'|'scalar'|'kong', spec: text, standalone?: exported page, snapshot?: everything expanded
   * for a static copy, dark?: forced theme }
   */
  async function render(options) {
    latest = options;
    const { viewer, spec } = options;
    const isDark = options.dark ?? (!options.snapshot && dark.matches);
    theme(isDark && viewer !== 'kong');
    if (!window[LIBS[viewer].global]) status(`Loading ${viewer === 'swagger' ? 'Swagger UI' : viewer === 'scalar' ? 'Scalar' : 'Kong'}…`);
    try {
      await ensure(viewer);
    } catch (e) {
      status(e.message);
      return;
    }
    if (latest !== options) return;
    status('');
    if (current && current.viewer !== viewer) {
      current.instance?.destroy?.();
      root().replaceChildren();
      current = null;
    }
    if (viewer === 'swagger') {
      if (!current) {
        const ui = window.SwaggerUIBundle({
          domNode: root(),
          spec: {},
          layout: 'BaseLayout',
          deepLinking: false,
          validatorUrl: null,
          // From the preview, requests would be blocked by CORS; run them from an .http scratch instead.
          supportedSubmitMethods: options.standalone && !options.snapshot ? undefined : [],
          defaultModelsExpandDepth: options.snapshot ? 1 : 0,
          docExpansion: options.snapshot ? 'full' : 'list',
        });
        current = { viewer, instance: ui };
      }
      current.instance.specActions.updateSpec(spec);
    } else if (viewer === 'scalar') {
      const config = scalarConfig(options, isDark);
      if (current?.instance?.updateConfiguration) {
        current.instance.updateConfiguration(config);
      } else {
        root().replaceChildren();
        const mount = document.createElement('div');
        root().appendChild(mount);
        current = { viewer, instance: window.Scalar.createApiReference(mount, config) };
      }
    } else {
      if (!customElements.get('kong-spec-renderer')) window.KongSpecRenderer.registerKongSpecRenderer();
      let el = current?.instance;
      if (!el) {
        el = document.createElement('kong-spec-renderer');
        el.setAttribute('navigation-type', 'hash');
        el.setAttribute('control-address-bar', 'false');
        if (options.snapshot) {
          el.setAttribute('allow-content-scrolling', 'true');
          el.setAttribute('hide-try-it', 'true');
        }
        if (!options.standalone) el.setAttribute('hide-download-button', 'true');
        root().replaceChildren(el);
        current = { viewer, instance: el };
      }
      el.spec = spec;
      el.setAttribute('spec', spec);
    }
  }

  dark.addEventListener('change', () => {
    if (!latest || latest.dark !== undefined || latest.snapshot) return;
    if (latest.viewer === 'scalar') current = (current?.instance?.destroy?.(), null);
    render(latest);
  });

  // ---------- static snapshot (MHTML export) ----------

  /** Resolves once the page has stopped changing for `quiet` ms (or after `max`). */
  function settle(quiet = 900, max = 20000) {
    return new Promise((resolve) => {
      let timer;
      const started = Date.now();
      const observer = new MutationObserver(() => {
        clearTimeout(timer);
        if (Date.now() - started > max) return done();
        timer = setTimeout(done, quiet);
      });
      function done() { observer.disconnect(); clearTimeout(timer); resolve(); }
      observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      timer = setTimeout(done, quiet);
    });
  }

  const VOID = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);
  const RAW = new Set(['style', 'script', 'xmp', 'iframe', 'noembed', 'noframes', 'plaintext']);
  const escText = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\u00a0/g, '&nbsp;');
  const escAttr = (s) => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/\u00a0/g, '&nbsp;');
  const sheetText = (sheets) => {
    let css = '';
    for (const sheet of sheets) {
      try { for (const rule of sheet.cssRules) css += rule.cssText + '\n'; } catch { /* cross-origin */ }
    }
    return css;
  };

  /** The live DOM as markup: shadow roots become declarative `<template shadowrootmode>`, rules added through the
   * CSSOM are written out, form state is kept, and scripts are dropped (the copy is static). */
  function serialize(node, parentTag) {
    if (node.nodeType === Node.TEXT_NODE) return RAW.has(parentTag) ? node.data : escText(node.data);
    if (node.nodeType === Node.DOCUMENT_FRAGMENT_NODE) return children(node, parentTag);
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    const tag = node.localName;
    if (tag === 'script' || tag === 'noscript' || tag === 'template' && !node.hasAttribute('shadowrootmode')) return '';
    if (tag === 'link' && /preload|stylesheet|icon/.test(node.rel)) return '';
    let attrs = '';
    for (const a of node.attributes) {
      if (/^on/i.test(a.name)) continue;
      if (tag === 'input' && (a.name === 'value' || a.name === 'checked')) continue;
      attrs += ` ${a.name}="${escAttr(a.value)}"`;
    }
    if (tag === 'input') {
      if (node.value) attrs += ` value="${escAttr(node.value)}"`;
      if (node.checked) attrs += ' checked';
    }
    if (tag === 'option' && node.selected && !node.hasAttribute('selected')) attrs += ' selected';
    if (VOID.has(tag)) return `<${tag}${attrs}>`;
    let inner;
    if (tag === 'style') inner = (node.sheet ? sheetText([node.sheet]) : node.textContent).replace(/<\/style/gi, '<\\/style');
    else if (tag === 'textarea') inner = escText(node.value);
    else inner = children(node, tag);
    if (node.shadowRoot) {
      const adopted = node.shadowRoot.adoptedStyleSheets?.length ? `<style>${sheetText(node.shadowRoot.adoptedStyleSheets)}</style>` : '';
      inner = `<template shadowrootmode="open">${adopted}${children(node.shadowRoot, '')}</template>` + inner;
    }
    return `<${tag}${attrs}>${inner}</${tag}>`;
  }
  function children(node, tag) {
    let out = '';
    for (let c = node.firstChild; c; c = c.nextSibling) out += serialize(c, tag);
    return out;
  }

  async function snapshot() {
    await new Promise((r) => setTimeout(r, 300));
    await settle();
    const head = document.head;
    const adopted = document.adoptedStyleSheets?.length ? `<style>${sheetText(document.adoptedStyleSheets)}</style>` : '';
    const htmlAttrs = [...document.documentElement.attributes].map((a) => ` ${a.name}="${escAttr(a.value)}"`).join('');
    return `<!DOCTYPE html>\n<html${htmlAttrs}><head>${children(head, 'head')}${adopted}</head>`
      + `${serialize(document.body, 'html')}</html>`;
  }

  window.SpecViewer = { render, snapshot };

  // The preview sends the spec (and viewer changes) from the editor page.
  window.addEventListener('message', (e) => {
    if (e.data?.type === 'spec') render(e.data.options);
  });
  window.parent?.postMessage({ type: 'viewerReady' }, '*');
})();
