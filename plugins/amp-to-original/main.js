(() => {
  if (window.top !== window) return;
  const amp = document.documentElement.hasAttribute('amp') || document.documentElement.hasAttribute('⚡') ||
    /\.cdn\.ampproject\.org$/.test(location.hostname) || /^\/amp\//.test(location.pathname) && location.hostname.endsWith('google.com');
  if (!amp) return;
  const canonical = document.querySelector('link[rel="canonical"]');
  if (!canonical || !canonical.href) return;
  const target = new URL(canonical.href, location.href);
  if (target.href !== location.href && /^https?:$/.test(target.protocol)) location.replace(target.href);
})();
