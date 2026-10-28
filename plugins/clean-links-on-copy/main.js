(() => {
  const tracking = /^(utm_[a-z_]+|fbclid|gclid|gclsrc|dclid|msclkid|mc_cid|mc_eid|igshid|yclid|_hsenc|_hsmi|mkt_tok|vero_id|ref_src|ref_url|spm|si|feature)$/i;
  const clean = (text) => {
    let url;
    try { url = new URL(text.trim()); } catch (e) { return null; }
    if (!/^https?:$/.test(url.protocol)) return null;
    // YouTube's si and feature, and Twitter's ref_src, are tracking; elsewhere "si" may mean something.
    const keys = [...url.searchParams.keys()].filter(k => tracking.test(k) && (!/^(si|feature)$/i.test(k) || /youtu/.test(url.hostname)));
    if (!keys.length) return null;
    keys.forEach(k => url.searchParams.delete(k));
    return url.toString().replace(/\?$/, '');
  };
  const toast = (text) => {
    const t = document.createElement('div');
    t.textContent = text;
    t.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);z-index:2147483647;background:rgba(20,20,28,.92);' +
      'color:#fff;font:13px -apple-system,sans-serif;padding:8px 14px;border-radius:10px;pointer-events:none;transition:opacity .3s';
    document.documentElement.appendChild(t);
    setTimeout(() => { t.style.opacity = '0'; }, 1200);
    setTimeout(() => t.remove(), 1600);
  };
  // Copying a selected address: the clipboard gets the clean one.
  document.addEventListener('copy', (e) => {
    const text = String(window.getSelection() || '');
    const cleaned = text.length < 4000 && !/\s/.test(text.trim()) ? clean(text) : null;
    if (!cleaned) return;
    e.clipboardData.setData('text/plain', cleaned);
    e.preventDefault();
    toast('Copied without tracking');
  }, true);
  const address = () => clean(location.href) || location.href;
  globalThis.tacetAction = () => { toast('Copied the clean address'); return { copy: address() }; };
  document.addEventListener('keydown', async (e) => {
    if (!(e.altKey && e.shiftKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyL')) return;
    e.preventDefault();
    try { await navigator.clipboard.writeText(address()); toast('Copied the clean address'); } catch (err) {}
  }, true);
})();
