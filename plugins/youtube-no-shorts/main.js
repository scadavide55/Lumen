// A Shorts page becomes the same video in the normal player, including when YouTube switches pages itself.
(() => {
  const toWatch = () => {
    const m = location.pathname.match(/^\/shorts\/([\w-]{6,})/);
    if (m) location.replace('/watch?v=' + m[1]);
  };
  toWatch();
  window.addEventListener('yt-navigate-start', toWatch);
  window.addEventListener('yt-navigate-finish', toWatch);
  window.addEventListener('popstate', toWatch);
})();
