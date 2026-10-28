// Dark pages for light sites: the page's colours are inverted and turned back for pictures and videos,
// but only after checking that the page is actually light.
(() => {
  if (window.top !== window) return;
  const style = document.createElement('style');
  style.dataset.tacetPlugin = 'smart-dark';
  style.textContent = `
    html.tacet-smart-dark { filter: invert(0.92) hue-rotate(180deg) !important; background: #fff !important; }
    html.tacet-smart-dark img, html.tacet-smart-dark picture, html.tacet-smart-dark video, html.tacet-smart-dark canvas,
    html.tacet-smart-dark iframe, html.tacet-smart-dark svg image, html.tacet-smart-dark [style*="background-image"] {
      filter: invert(1) hue-rotate(180deg) !important; }
  `;
  // Hide the light page until it's been checked, so it doesn't flash white.
  const cover = document.createElement('style');
  cover.textContent = 'html { background: #1b1b1f !important; }';
  (document.head || document.documentElement).append(style, cover);
  const luminance = (c) => {
    const m = c.match(/rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?/);
    if (!m || (m[4] !== undefined && +m[4] < 0.1)) return null;
    return (0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3]) / 255;
  };
  const decide = () => {
    cover.remove();
    const bg = [document.body, document.documentElement].map(e => e && luminance(getComputedStyle(e).backgroundColor)).find(v => v !== null && v !== undefined);
    const prefersDark = document.querySelector('meta[name="color-scheme"][content*="dark"]') && !document.querySelector('meta[name="color-scheme"][content*="light"]');
    if ((bg === undefined || bg > 0.6) && !prefersDark) document.documentElement.classList.add('tacet-smart-dark');
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', decide); else decide();
})();
