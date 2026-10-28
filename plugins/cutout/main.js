// On every site: rest the pointer on a picture and a "Cutout" button appears on it (or press ⌥⇧X). Tacet then opens
// Cutout in a new tab with that picture in it, ready to remove its background, all on this Mac.
(() => {
  if (window.top !== window || location.protocol === 'tacet-plugin:') return;
  let pill = null, current = null, hideTimer = null, showTimer = null;

  const big = (img) => {
    const r = img.getBoundingClientRect();
    return r.width >= 160 && r.height >= 120 && img.complete && img.naturalWidth >= 200;
  };

  const send = async (img) => {
    const src = img.currentSrc || img.src;
    const name = (img.alt || src.split('/').pop().split('?')[0] || 'image').slice(0, 80);
    const message = { action: 'handoffImage', name };
    // Pictures this page can read (its own, data: and blob: ones, or ones shared with CORS) go straight across.
    try {
      if (/^(data|blob):/.test(src) || new URL(src).origin === location.origin) {
        const blob = await (await fetch(src)).blob();
        if (blob.type.startsWith('image/') && blob.size <= 30000000) {
          const b64 = await new Promise((res) => { const fr = new FileReader(); fr.onload = () => res(String(fr.result).split(',')[1]); fr.readAsDataURL(blob); });
          message.data = b64;
          message.type = blob.type;
        }
      }
    } catch (e) {}
    // Any other picture: Tacet downloads it itself, from public addresses only.
    if (!message.data) message.url = src;
    try { webkit.messageHandlers.tacetPlugin.postMessage(message); } catch (e) {}
  };

  const makePill = () => {
    const b = document.createElement('button');
    b.textContent = '✂ Cutout';
    b.title = 'Remove the background with Cutout (⌥⇧X)';
    b.style.cssText = 'position:fixed;z-index:2147483646;padding:5px 10px;border:0;border-radius:999px;cursor:pointer;' +
      'background:rgba(20,20,28,.88);color:#fff;font:600 12px -apple-system,sans-serif;box-shadow:0 4px 16px rgba(0,0,0,.3);' +
      'opacity:0;transition:opacity .15s;pointer-events:auto';
    b.addEventListener('mouseenter', () => clearTimeout(hideTimer));
    b.addEventListener('mouseleave', () => hide());
    b.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); if (current) send(current); hide(true); });
    document.documentElement.appendChild(b);
    return b;
  };

  const show = (img) => {
    current = img;
    pill = pill || makePill();
    const r = img.getBoundingClientRect();
    pill.style.top = Math.max(6, r.top + 8) + 'px';
    pill.style.left = Math.max(6, Math.min(innerWidth - 100, r.right - 92)) + 'px';
    pill.style.opacity = '1';
    pill.style.display = 'block';
  };

  const hide = (now) => {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => { if (pill) { pill.style.opacity = '0'; pill.style.display = 'none'; } current = null; }, now ? 0 : 250);
  };

  document.addEventListener('mouseover', (e) => {
    const img = e.target && e.target.tagName === 'IMG' ? e.target : null;
    clearTimeout(showTimer);
    if (img && big(img)) {
      clearTimeout(hideTimer);
      showTimer = setTimeout(() => show(img), 350);
    } else if (pill && e.target !== pill) {
      hide();
    }
  }, true);
  addEventListener('scroll', () => hide(true), { passive: true });

  document.addEventListener('keydown', (e) => {
    if (!(e.altKey && e.shiftKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyX')) return;
    const img = current || document.querySelector('img:hover');
    if (img && big(img)) { e.preventDefault(); send(img); hide(true); }
  }, true);
})();
