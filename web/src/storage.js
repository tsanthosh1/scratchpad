// localStorage can be unavailable (or throw) for file:// pages in WKWebView; fall back to memory.
const memory = new Map();

export const storage = {
  get(key) {
    try {
      return window.localStorage.getItem(key);
    } catch {
      return memory.get(key) ?? null;
    }
  },
  set(key, value) {
    memory.set(key, value);
    try {
      window.localStorage.setItem(key, value);
    } catch {}
  },
  remove(key) {
    memory.delete(key);
    try {
      window.localStorage.removeItem(key);
    } catch {}
  },
};
