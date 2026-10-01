import { marked } from 'marked';
import DOMPurify from 'dompurify';

const post = (msg) => window.webkit?.messageHandlers?.bridge?.postMessage(msg);

marked.setOptions({ gfm: true, breaks: false });

/**
 * Renders Markdown (sanitised, in-page) or HTML (sandboxed iframe with scripts disabled)
 * next to or instead of the editor.
 */
export class Preview {
  constructor(container) {
    this.container = container;
    this.markdownEl = container.querySelector('.markdown-body');
    this.frame = container.querySelector('iframe');
    this.language = null;
    this.timer = null;

    this.markdownEl.addEventListener('click', (e) => {
      const link = e.target.closest('a[href]');
      if (!link) return;
      e.preventDefault();
      const href = link.getAttribute('href');
      if (href.startsWith('#')) {
        this.markdownEl.querySelector(`[id="${CSS.escape(decodeURIComponent(href.slice(1)))}"]`)?.scrollIntoView();
      } else {
        post({ type: 'openURL', url: link.href });
      }
    });
  }

  render(language, text) {
    this.language = language;
    if (language === 'markdown') {
      this.frame.hidden = true;
      this.markdownEl.hidden = false;
      const html = marked.parse(text, { async: false });
      this.markdownEl.innerHTML = DOMPurify.sanitize(html);
      this.markdownEl.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach((h) => {
        h.id = h.textContent.trim().toLowerCase().replace(/[^\w\- ]/g, '').replace(/\s+/g, '-');
      });
    } else {
      this.markdownEl.hidden = true;
      this.frame.hidden = false;
      this.frame.srcdoc = text;
    }
  }

  scheduleRender(language, text) {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.render(language, text), 150);
  }

  /** Keeps the preview roughly aligned with the editor scroll position (Markdown only). */
  syncScroll(ratio) {
    if (this.language !== 'markdown') return;
    const el = this.container;
    el.scrollTop = ratio * (el.scrollHeight - el.clientHeight);
  }
}
