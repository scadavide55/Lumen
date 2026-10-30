import WebKit

/// Lets the assistant click, type, scroll and drag on the current page. Elements are found by numbers that this
/// script hands out, kept in its own JavaScript world, so the page can neither see nor forge them.
/// Password and payment card fields are never filled in.
enum PageControl {
    static let world = WKContentWorld.world(name: "LumenAssistant")

    /// Shared helpers, defined once per page in the assistant's world.
    private static let prelude = """
    const L = window.__lumen || (window.__lumen = { refs: new Map(), ids: new WeakMap(), n: 0 });
    const visible = el => {
      const r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return false;
      const s = getComputedStyle(el);
      return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
    };
    const ref = el => {
      let id = L.ids.get(el);
      if (!id) { id = ++L.n; L.ids.set(el, id); L.refs.set(id, new WeakRef(el)); }
      return id;
    };
    const byRef = id => { const w = L.refs.get(Number(id)); const el = w && w.deref(); return el && el.isConnected ? el : null; };
    const clean = s => (s || '').replace(/\\s+/g, ' ').trim();
    const label = el => {
      const byId = el.id && document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
      const t = el.getAttribute('aria-label') || (el.labels && el.labels[0] && el.labels[0].innerText) || (byId && byId.innerText)
        || (['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName) ? '' : el.innerText)
        || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || el.getAttribute('name') || '';
      return clean(t).slice(0, 80);
    };
    const secret = el => {
      const type = (el.getAttribute('type') || '').toLowerCase();
      const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
      const name = ((el.getAttribute('name') || '') + ' ' + (el.id || '')).toLowerCase();
      return type === 'password' || ac.includes('password') || ac.startsWith('cc-') || /card.?num|cvc|cvv|iban/.test(name);
    };
    const center = el => {
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const r = el.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    };
    const mouse = (el, type, p, extra) => el.dispatchEvent(new (type.startsWith('pointer') ? PointerEvent : MouseEvent)(type,
      Object.assign({ bubbles: true, cancelable: true, composed: true, view: window, clientX: p.x, clientY: p.y, button: 0, buttons: type.endsWith('up') ? 0 : 1 }, extra || {})));
    """

    private static let findScript = prelude + """
    const query = (args.query || '').toLowerCase();
    const sel = 'a[href],button,input:not([type=hidden]),textarea,select,summary,label,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=switch],[role=combobox],[role=textbox],[role=slider],[contenteditable=""],[contenteditable=true],[onclick],[draggable=true],[tabindex]:not([tabindex="-1"])';
    const lines = [];
    let total = 0;
    for (const el of document.querySelectorAll(sel)) {
      if (!visible(el) || (el.tagName === 'LABEL' && el.control)) continue;
      const name = label(el);
      const tag = el.tagName.toLowerCase();
      const role = el.getAttribute('role') || (tag === 'a' ? 'link' : tag);
      let line = '[' + ref(el) + '] ' + role;
      if (tag === 'input') line += ' type=' + (el.type || 'text');
      if (name) line += ' "' + name + '"';
      if (secret(el)) line += ' (password or card field: off limits)';
      else if (['input', 'textarea'].includes(tag) && !['checkbox', 'radio', 'submit', 'button'].includes(el.type)) line += ' value="' + clean(el.value).slice(0, 80) + '"';
      else if (el.isContentEditable) line += ' editable';
      if (tag === 'select') line += ' selected="' + clean(el.selectedOptions[0] && el.selectedOptions[0].text) + '" options=' + JSON.stringify([...el.options].slice(0, 30).map(o => clean(o.text)));
      if (el.checked !== undefined && ['checkbox', 'radio'].includes(el.type)) line += el.checked ? ' checked' : ' unchecked';
      if (el.getAttribute('aria-checked')) line += ' aria-checked=' + el.getAttribute('aria-checked');
      if (el.getAttribute('aria-expanded')) line += ' expanded=' + el.getAttribute('aria-expanded');
      if (el.disabled) line += ' disabled';
      if (el.draggable && tag !== 'a' && tag !== 'img') line += ' draggable';
      if (tag === 'a' && el.href) line += ' -> ' + el.href.slice(0, 160);
      const r = el.getBoundingClientRect();
      if (r.bottom < 0 || r.top > innerHeight) line += ' (off screen)';
      if (query && !line.toLowerCase().includes(query)) continue;
      total++;
      if (lines.length < 200) lines.push(line);
    }
    const max = document.documentElement.scrollHeight - innerHeight;
    const where = 'Scrolled ' + (max > 0 ? Math.round(100 * scrollY / max) : 100) + '% down. ';
    return where + (total ? total + ' elements' + (total > lines.length ? ', first ' + lines.length + ' shown' : '') + ':\\n' + lines.join('\\n') : 'No matching elements.');
    """

    private static let clickScript = prelude + """
    const el = byRef(args.ref);
    if (!el) return 'ERROR: element ' + args.ref + ' is gone. Call find_elements again.';
    if (el.disabled) return 'ERROR: element ' + args.ref + ' is disabled.';
    const p = center(el);
    const top = document.elementFromPoint(p.x, p.y);
    const target = top && (el === top || el.contains(top)) ? top : el;
    for (const t of ['pointerover', 'mouseover', 'pointerdown', 'mousedown']) mouse(target, t, p);
    if (target.focus) target.focus({ preventScroll: true });
    for (const t of ['pointerup', 'mouseup']) mouse(target, t, p);
    target.click();
    return 'Clicked [' + args.ref + '] ' + label(el);
    """

    private static let typeScript = prelude + """
    const el = byRef(args.ref);
    if (!el) return 'ERROR: element ' + args.ref + ' is gone. Call find_elements again.';
    if (secret(el)) return 'ERROR: this is a password or payment card field. Tacet Assistant never fills these in; ask the user to type it.';
    if (el.disabled || el.readOnly) return 'ERROR: element ' + args.ref + ' cannot be edited.';
    center(el);
    el.focus({ preventScroll: true });
    const text = String(args.text);
    if (el.tagName === 'SELECT') {
      const o = [...el.options].find(o => clean(o.text).toLowerCase() === text.toLowerCase() || o.value === text)
        || [...el.options].find(o => clean(o.text).toLowerCase().includes(text.toLowerCase()));
      if (!o) return 'ERROR: no option matches "' + text + '".';
      el.value = o.value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return 'Selected "' + clean(o.text) + '" in [' + args.ref + ']';
    }
    if (el.isContentEditable) {
      if (args.clear !== false) document.execCommand('selectAll', false, null);
      document.execCommand('insertText', false, text);
    } else if ('value' in el) {
      const proto = Object.getPrototypeOf(el);
      const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
      const value = args.clear === false ? el.value + text : text;
      setter ? setter.call(el, value) : (el.value = value);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    } else {
      return 'ERROR: element ' + args.ref + ' is not a text field.';
    }
    if (args.submit) {
      const key = t => el.dispatchEvent(new KeyboardEvent(t, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true }));
      const allowed = key('keydown');
      key('keypress'); key('keyup');
      if (allowed && el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
      return 'Typed into [' + args.ref + '] ' + label(el) + ' and pressed Return';
    }
    return 'Typed into [' + args.ref + '] ' + label(el);
    """

    private static let scrollScript = prelude + """
    if (args.ref) {
      const el = byRef(args.ref);
      if (!el) return 'ERROR: element ' + args.ref + ' is gone. Call find_elements again.';
      center(el);
      return 'Scrolled to [' + args.ref + '] ' + label(el);
    }
    const pages = Math.max(0.25, Math.min(10, Number(args.pages) || 1));
    const d = { up: [0, -1], down: [0, 1], left: [-1, 0], right: [1, 0] }[args.direction] || [0, 1];
    // The page itself, or the largest scrollable area when the page doesn't scroll (as in many web apps).
    let box = document.scrollingElement;
    if (box.scrollHeight <= innerHeight + 2) {
      let best = 0;
      for (const el of document.querySelectorAll('*')) {
        const s = getComputedStyle(el);
        if (!/(auto|scroll)/.test(s.overflowY + s.overflowX) || el.scrollHeight <= el.clientHeight + 2) continue;
        const a = el.clientWidth * el.clientHeight;
        if (a > best) { best = a; box = el; }
      }
    }
    const w = box === document.scrollingElement ? innerWidth : box.clientWidth;
    const h = box === document.scrollingElement ? innerHeight : box.clientHeight;
    box.scrollBy({ left: d[0] * w * 0.8 * pages, top: d[1] * h * 0.8 * pages, behavior: 'instant' });
    const max = box.scrollHeight - box.clientHeight;
    const pct = max > 0 ? Math.round(100 * box.scrollTop / max) : 100;
    return 'Scrolled ' + args.direction + '. Now ' + pct + '% down' + (pct >= 100 ? ' (at the bottom)' : box.scrollTop <= 0 ? ' (at the top)' : '') + '.';
    """

    private static let dragScript = prelude + """
    const from = byRef(args.from_ref), to = byRef(args.to_ref);
    if (!from || !to) return 'ERROR: element ' + (from ? args.to_ref : args.from_ref) + ' is gone. Call find_elements again.';
    const a = center(from);
    const r = to.getBoundingClientRect();
    const b = { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    // Mouse events for libraries that follow the pointer, then HTML drag and drop events.
    mouse(from, 'pointerdown', a); mouse(from, 'mousedown', a);
    for (let i = 1; i <= 10; i++) {
      const p = { x: a.x + (b.x - a.x) * i / 10, y: a.y + (b.y - a.y) * i / 10 };
      const over = document.elementFromPoint(p.x, p.y) || to;
      mouse(over, 'pointermove', p); mouse(over, 'mousemove', p);
    }
    mouse(to, 'pointerup', b); mouse(to, 'mouseup', b);
    const dt = new DataTransfer();
    const drag = (el, t, p) => el.dispatchEvent(new DragEvent(t, { bubbles: true, cancelable: true, composed: true, clientX: p.x, clientY: p.y, dataTransfer: dt }));
    drag(from, 'dragstart', a); drag(to, 'dragenter', b); drag(to, 'dragover', b); drag(to, 'drop', b); drag(from, 'dragend', b);
    return 'Dragged [' + args.from_ref + '] ' + label(from) + ' onto [' + args.to_ref + '] ' + label(to);
    """

    enum Action {
        case find, click, type, scroll, drag
        var script: String {
            switch self {
            case .find: findScript
            case .click: clickScript
            case .type: typeScript
            case .scroll: scrollScript
            case .drag: dragScript
            }
        }
    }

    /// Runs an action on the page and returns its result for the model; results starting with ERROR are failures.
    @MainActor
    static func run(_ action: Action, args: [String: Any], in webView: WKWebView) async -> (String, Bool) {
        var safe: [String: Any] = [:]
        for (k, v) in args where JSONSerialization.isValidJSONObject([v]) { safe[k] = v }
        do {
            let result = try await webView.callAsyncJavaScript(action.script, arguments: ["args": safe], in: nil, contentWorld: world)
            let text = result as? String ?? ""
            return (text, text.hasPrefix("ERROR"))
        } catch {
            return ("ERROR: the page didn't allow this: \(error.localizedDescription)", true)
        }
    }

    /// Whether clicking an element (or pressing Return in it) could send, buy, delete or publish something: a form's
    /// submit button, or a control whose words say so. Those wait for the user's OK, whatever the model was told.
    @MainActor
    static func risk(of ref: Any?, submitting: Bool, in webView: WKWebView) async -> (label: String, risky: Bool) {
        let js = prelude + """
        const el = byRef(args.ref);
        if (!el) return ['', false];
        const words = /\\b(send|buy|purchase|pay|order|checkout|check out|delete|remove|confirm|submit|publish|post|share|subscribe|unsubscribe|transfer|donate|book|reserve|sign out|log out|invia|acquista|compra|paga|ordina|elimina|cancella|rimuovi|conferma|pubblica|condividi|iscriviti|trasferisci|dona|prenota|esci|envoyer|acheter|payer|commander|supprimer|confirmer|publier|partager|réserver|donner)\\b/i;
        const text = [label(el), el.getAttribute('aria-label') || '', el.value || '', el.title || ''].join(' ');
        const submit = (el.tagName === 'BUTTON' && (el.getAttribute('type') || 'submit') === 'submit' && !!el.form)
          || (el.tagName === 'INPUT' && ['submit', 'image'].includes(el.type));
        return [label(el), submit || (args.submitting && !!el.form) || words.test(text)];
        """
        let r = try? await webView.callAsyncJavaScript(js, arguments: ["args": ["ref": ref ?? 0, "submitting": submitting]], in: nil, contentWorld: world)
        let pair = r as? [Any] ?? []
        return ((pair.first as? String) ?? "", (pair.last as? Bool) ?? true)
    }

    /// Short words for the activity line, such as "Clicking “Sign in”".
    @MainActor
    static func label(of ref: Any?, in webView: WKWebView) async -> String {
        let js = prelude + "const el = byRef(args.ref); return el ? label(el) : '';"
        let r = try? await webView.callAsyncJavaScript(js, arguments: ["args": ["ref": ref ?? 0]], in: nil, contentWorld: world)
        return (r as? String) ?? ""
    }
}
