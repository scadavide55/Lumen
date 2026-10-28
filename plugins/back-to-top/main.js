(() => {
  if (window.top !== window) return;
  const b = document.createElement('button');
  b.textContent = '↑';
  b.title = 'Back to top';
  b.style.cssText = 'position:fixed;right:20px;bottom:20px;z-index:2147483646;width:38px;height:38px;border-radius:50%;border:0;' +
    'background:rgba(20,20,28,.8);color:#fff;font:600 18px -apple-system,sans-serif;cursor:pointer;opacity:0;pointer-events:none;' +
    'transition:opacity .25s;box-shadow:0 6px 20px rgba(0,0,0,.25)';
  b.addEventListener('click', () => scrollTo({ top: 0, behavior: 'smooth' }));
  document.documentElement.appendChild(b);
  const update = () => {
    const show = scrollY > innerHeight * 1.5;
    b.style.opacity = show ? '1' : '0';
    b.style.pointerEvents = show ? 'auto' : 'none';
  };
  addEventListener('scroll', update, { passive: true });
  update();
})();
