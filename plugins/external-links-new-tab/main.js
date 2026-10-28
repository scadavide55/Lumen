(() => {
  const site = (h) => h.split('.').slice(-2).join('.');
  const here = site(location.hostname);
  document.addEventListener('click', (e) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = e.target.closest && e.target.closest('a[href]');
    if (!a || a.target === '_blank' || a.hasAttribute('download')) return;
    let url;
    try { url = new URL(a.href, location.href); } catch (err) { return; }
    if (!/^https?:$/.test(url.protocol) || site(url.hostname) === here) return;
    e.preventDefault();
    window.open(url.href, '_blank', 'noopener');
  }, true);
})();
