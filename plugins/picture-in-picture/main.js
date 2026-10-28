(() => {
  const toggle = async () => {
    const v = [...document.querySelectorAll('video')].filter(x => x.offsetWidth > 0)
      .sort((a, b) => b.offsetWidth * b.offsetHeight - a.offsetWidth * a.offsetHeight)[0];
    if (!v) return { message: 'There is no video on this page.' };
    try {
      if (document.pictureInPictureElement) await document.exitPictureInPicture();
      else {
        v.removeAttribute('disablepictureinpicture');
        if (v.requestPictureInPicture) await v.requestPictureInPicture();
        else if (v.webkitSetPresentationMode) v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
      }
    } catch (err) {}
    return null;
  };
  globalThis.tacetAction = toggle;
  document.addEventListener('keydown', (e) => {
    if (!(e.altKey && e.shiftKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyP')) return;
    e.preventDefault();
    toggle();
  }, true);
})();
