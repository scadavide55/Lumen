(() => {
  const toast = (text) => {
    const t = document.createElement('div');
    t.textContent = text;
    t.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);z-index:2147483647;' +
      'background:rgba(20,20,28,.92);color:#fff;font:13px -apple-system,sans-serif;padding:8px 14px;border-radius:10px;' +
      'box-shadow:0 8px 30px rgba(0,0,0,.3);pointer-events:none;transition:opacity .3s';
    document.documentElement.appendChild(t);
    setTimeout(() => { t.style.opacity = '0'; }, 1200);
    setTimeout(() => t.remove(), 1600);
  };
  const typing = (e) => { const el = e.target; return el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)); };
  const count = () => {
    const sel = String(window.getSelection() || '').trim();
    const text = sel || (document.querySelector('article') || document.body).innerText;
    const words = text.split(/\s+/).filter(Boolean).length;
    const minutes = Math.max(1, Math.round(words / 230));
    toast((sel ? 'Selection: ' : 'Page: ') + words.toLocaleString() + ' words · ' + text.length.toLocaleString() + ' characters · ' + minutes + ' min');
  };
  globalThis.tacetAction = count;
  document.addEventListener('keydown', (e) => {
    if (!(e.altKey && e.shiftKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyW')) return;
    e.preventDefault();
    count();
  }, true);
})();
