(() => {
  const h = location.hostname;
  if (h === 'old.reddit.com') return;
  if (!/^(www\.)?reddit\.com$/.test(h)) return;
  // These only exist in the new design.
  if (/^\/(gallery|chat|settings|media|poll|notifications|appeal|answers)\b/.test(location.pathname)) return;
  location.replace('https://old.reddit.com' + location.pathname + location.search + location.hash);
})();
