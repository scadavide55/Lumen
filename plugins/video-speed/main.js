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
  const video = () => [...document.querySelectorAll('video')].filter(v => v.offsetWidth > 0).sort((a, b) => b.offsetWidth * b.offsetHeight - a.offsetWidth * a.offsetHeight)[0];
  document.addEventListener('keydown', (e) => {
    if (typing(e) || e.metaKey || e.ctrlKey || e.altKey || !['[', ']', '\\'].includes(e.key)) return;
    const v = video();
    if (!v) return;
    e.preventDefault(); e.stopPropagation();
    const rate = e.key === '\\' ? 1 : Math.min(4, Math.max(0.25, v.playbackRate + (e.key === ']' ? 0.25 : -0.25)));
    v.playbackRate = rate;
    toast(rate.toFixed(2).replace(/\.?0+$/, '') + '×');
  }, true);
})();
