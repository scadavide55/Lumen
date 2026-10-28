(() => {
  document.addEventListener('keydown', async (e) => {
    if (!(e.altKey && e.shiftKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyP')) return;
    const v = [...document.querySelectorAll('video')].filter(x => x.offsetWidth > 0)
      .sort((a, b) => b.offsetWidth * b.offsetHeight - a.offsetWidth * a.offsetHeight)[0];
    if (!v) return;
    e.preventDefault();
    try {
      if (document.pictureInPictureElement) await document.exitPictureInPicture();
      else {
        v.removeAttribute('disablepictureinpicture');
        if (v.requestPictureInPicture) await v.requestPictureInPicture();
        else if (v.webkitSetPresentationMode) v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
      }
    } catch (err) {}
  }, true);
})();
