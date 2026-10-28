// Only on pages that are mostly one long text: an article, a blog post, Reader.
(() => {
  if (window.top !== window) return;
  const article = document.querySelector('article') || document.querySelector('main') || document.body;
  const words = (article.innerText || '').split(/\s+/).filter(Boolean).length;
  if (words < 600 || document.documentElement.scrollHeight < innerHeight * 2) return;

  const bar = document.createElement('div');
  bar.style.cssText = 'position:fixed;top:0;left:0;height:3px;width:0;z-index:2147483647;pointer-events:none;' +
    'background:linear-gradient(90deg,#ffc24a,#ff5a2a);transition:width .1s linear';
  const label = document.createElement('div');
  label.style.cssText = 'position:fixed;bottom:16px;right:16px;z-index:2147483647;pointer-events:none;' +
    'font:11.5px -apple-system,sans-serif;color:#fff;background:rgba(20,20,28,.75);padding:4px 9px;border-radius:999px;' +
    'opacity:0;transition:opacity .3s';
  document.documentElement.append(bar, label);

  const minutes = words / 230;
  let hide;
  const update = () => {
    const rect = article.getBoundingClientRect();
    const total = Math.max(1, rect.height - innerHeight);
    const done = Math.min(1, Math.max(0, -rect.top / total));
    bar.style.width = (done * 100) + '%';
    const left = Math.ceil(minutes * (1 - done));
    label.textContent = done >= 0.99 ? 'Done' : left + ' min left';
    label.style.opacity = '1';
    clearTimeout(hide);
    hide = setTimeout(() => { label.style.opacity = '0'; }, 1500);
  };
  addEventListener('scroll', update, { passive: true });
  addEventListener('resize', update);
  update();
  label.style.opacity = '0';
})();
