(() => {
  if (window.top !== window) return;
  // Sites with their own single-key shortcuts (YouTube's F, J and K, Gmail, X, GitHub…) keep them.
  const own = ['youtube.com', 'mail.google.com', 'docs.google.com', 'x.com', 'twitter.com', 'github.com', 'figma.com', 'notion.so', 'reddit.com'];
  if (own.some(d => location.hostname === d || location.hostname.endsWith('.' + d))) return;
  const typing = (e) => { const el = e.target; return el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)); };
  let hints = null, typed = '', newTab = false;
  const letters = 'asdfghjklqwertyuiopzxcvbnm';
  const label = (i, n) => { const len = n > letters.length ? 2 : 1; let s = ''; for (let k = 0; k < len; k++) { s = letters[i % letters.length] + s; i = Math.floor(i / letters.length); } return s; };
  const clear = () => { if (hints) hints.layer.remove(); hints = null; typed = ''; };
  const show = (tab) => {
    const els = [...document.querySelectorAll('a[href], button, [role="button"], input:not([type=hidden]), textarea, select, summary')]
      .filter(el => { const r = el.getBoundingClientRect(); return r.width > 2 && r.height > 2 && r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth && getComputedStyle(el).visibility !== 'hidden'; })
      .slice(0, 600);
    if (!els.length) return;
    const layer = document.createElement('div');
    layer.style.cssText = 'position:fixed;inset:0;z-index:2147483647;pointer-events:none';
    const map = els.map((el, i) => {
      const r = el.getBoundingClientRect();
      const tag = document.createElement('span');
      tag.textContent = label(i, els.length).toUpperCase();
      tag.style.cssText = 'position:fixed;left:' + Math.max(0, r.left) + 'px;top:' + Math.max(0, r.top) + 'px;background:#ffc24a;color:#14121d;' +
        'font:700 11px ui-monospace,Menlo,monospace;padding:1px 4px;border-radius:4px;box-shadow:0 1px 3px rgba(0,0,0,.4)';
      layer.appendChild(tag);
      return { el, code: label(i, els.length), tag };
    });
    document.documentElement.appendChild(layer);
    hints = { layer, map }; typed = ''; newTab = tab;
  };
  document.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (hints) {
      e.preventDefault(); e.stopPropagation();
      if (e.key === 'Escape') return clear();
      if (e.key === 'Backspace') typed = typed.slice(0, -1); else if (e.key.length === 1) typed += e.key.toLowerCase();
      const left = hints.map.filter(h => h.code.startsWith(typed));
      hints.map.forEach(h => { h.tag.style.opacity = h.code.startsWith(typed) ? '1' : '0.15'; });
      if (left.length === 1 && left[0].code === typed) {
        const el = left[0].el; const tab = newTab; clear();
        if (tab && el.href) window.open(el.href, '_blank'); else if (/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)) el.focus(); else el.click();
      } else if (!left.length) clear();
      return;
    }
    if (typing(e)) return;
    const k = e.key;
    if (k === 'f' || k === 'F') { e.preventDefault(); show(k === 'F'); }
    else if (k === 'j') scrollBy({ top: 80 });
    else if (k === 'k') scrollBy({ top: -80 });
    else if (k === 'g') scrollTo({ top: 0 });
    else if (k === 'G') scrollTo({ top: document.documentElement.scrollHeight });
  }, true);
  addEventListener('scroll', () => { if (hints) clear(); }, { passive: true });
})();
