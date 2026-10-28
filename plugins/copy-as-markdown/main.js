(() => {
  const md = (node) => {
    if (node.nodeType === Node.TEXT_NODE) return node.nodeValue.replace(/\s+/g, ' ');
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    const tag = node.tagName.toLowerCase();
    if (['script', 'style', 'noscript', 'svg', 'button'].includes(tag)) return '';
    const inner = () => [...node.childNodes].map(md).join('');
    switch (tag) {
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6':
        return '\n\n' + '#'.repeat(+tag[1]) + ' ' + inner().trim() + '\n\n';
      case 'p': case 'div': case 'section': case 'article': return '\n\n' + inner().trim() + '\n\n';
      case 'br': return '  \n';
      case 'strong': case 'b': { const t = inner().trim(); return t ? '**' + t + '**' : ''; }
      case 'em': case 'i': { const t = inner().trim(); return t ? '*' + t + '*' : ''; }
      case 'code': return node.closest('pre') ? inner() : '`' + inner() + '`';
      case 'pre': return '\n\n```\n' + node.innerText.replace(/\n$/, '') + '\n```\n\n';
      case 'blockquote': return '\n\n' + inner().trim().split('\n').map(l => '> ' + l).join('\n') + '\n\n';
      case 'a': {
        const t = inner().trim();
        const href = node.href;
        return href && t && !href.startsWith('javascript:') ? '[' + t + '](' + href + ')' : t;
      }
      case 'img': return node.alt ? '![' + node.alt + '](' + node.src + ')' : '';
      case 'li': {
        const list = node.parentElement;
        const marker = list && list.tagName === 'OL' ? ([...list.children].indexOf(node) + 1) + '. ' : '- ';
        return '\n' + marker + inner().trim();
      }
      case 'ul': case 'ol': return '\n' + inner() + '\n';
      case 'hr': return '\n\n---\n\n';
      default: return inner();
    }
  };
  const toast = (text) => {
    const t = document.createElement('div');
    t.textContent = text;
    t.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);z-index:2147483647;' +
      'background:rgba(20,20,28,.92);color:#fff;font:13px -apple-system,sans-serif;padding:8px 14px;border-radius:10px;' +
      'box-shadow:0 8px 30px rgba(0,0,0,.3);pointer-events:none;transition:opacity .3s';
    document.documentElement.appendChild(t);
    setTimeout(() => { t.style.opacity = '0'; }, 1400);
    setTimeout(() => t.remove(), 1800);
  };
  document.addEventListener('keydown', async (e) => {
    if (!(e.altKey && e.shiftKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyC')) return;
    e.preventDefault();
    const sel = window.getSelection();
    let text;
    if (sel && !sel.isCollapsed && sel.rangeCount) {
      const box = document.createElement('div');
      for (let i = 0; i < sel.rangeCount; i++) box.appendChild(sel.getRangeAt(i).cloneContents());
      text = md(box).replace(/\n{3,}/g, '\n\n').trim();
    } else {
      text = '[' + document.title.replace(/[\[\]]/g, '') + '](' + location.href + ')';
    }
    try {
      await navigator.clipboard.writeText(text);
      toast('Copied as Markdown');
    } catch (err) {
      toast('Couldn\'t copy');
    }
  }, true);
})();
