import WebKit

/// JavaScript that Lumen injects into pages. Helpers run in an isolated content world so
/// pages cannot see or spoof them; only scripts that must patch page objects run in `.page`.
enum Scripts {
    static func install(on c: WKUserContentController) {
        let s = Settings.shared
        c.removeAllUserScripts()
        c.removeScriptMessageHandler(forName: "lumen", contentWorld: .defaultClient)
        c.add(ScriptBridge.shared, contentWorld: .defaultClient, name: "lumen")

        c.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        c.addUserScript(WKUserScript(source: logins, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        if s.gpc {
            c.addUserScript(WKUserScript(source: gpc, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        let allow = json(s.allowlist)
        if s.adBlock && s.hideCookieBanners {
            c.addUserScript(WKUserScript(source: cookieBanners.replacingOccurrences(of: "__ALLOW__", with: allow),
                                         injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        }
        if s.adBlock && s.youtubeAds {
            c.addUserScript(WKUserScript(source: youtube.replacingOccurrences(of: "__ALLOW__", with: allow),
                                         injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        if s.forceDark {
            c.addUserScript(WKUserScript(source: forceDark, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        }
        let styles = s.siteStyles.filter { $0.enabled && !$0.host.isEmpty && !$0.css.isEmpty }
            .map { ["host": $0.host.lowercased(), "css": $0.css] }
        if !styles.isEmpty {
            c.addUserScript(WKUserScript(source: siteStyles.replacingOccurrences(of: "__RULES__", with: json(styles)),
                                         injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Bridge: favicon, hovered link, media state, mute

    static let bridge = #"""
    (() => {
      if (window.__lumen) return;
      window.__lumen = true;
      const post = (m) => { try { webkit.messageHandlers.lumen.postMessage(m); } catch (e) {} };

      const icon = () => {
        let best = null, bestScore = -1;
        for (const l of document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]')) {
          const href = l.href;
          if (!href) continue;
          const type = (l.type || '').toLowerCase();
          if (type.includes('svg') || /\.svg(\?|$)/i.test(href)) continue;
          const sizes = ((l.sizes && l.sizes.value) || '').split(/\s+/).map(s => parseInt(s, 10) || 0);
          let size = Math.max(0, ...sizes) || (l.rel.includes('apple-touch-icon') ? 180 : 32);
          const score = 1000 - Math.abs(64 - size);
          if (score > bestScore) { best = href; bestScore = score; }
        }
        post({ type: 'favicon', href: best || (location.origin + '/favicon.ico') });
      };
      icon();
      window.addEventListener('load', icon, { once: true });

      let hovered = null;
      const setHover = (href) => { if (href !== hovered) { hovered = href; post({ type: 'hover', url: href }); } };
      document.addEventListener('mouseover', (e) => {
        const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        setHover(a && a.href && !a.href.startsWith('javascript:') ? a.href : null);
      }, true);
      document.documentElement.addEventListener('mouseleave', () => setHover(null));
      window.addEventListener('blur', () => setHover(null));

      // Whether the page (or the panel last scrolled) is at its top, for pull to refresh.
      let atTop = true, lastScroller = null;
      const checkTop = () => {
        const top = (window.scrollY || 0) <= 0 && (!lastScroller || lastScroller.scrollTop <= 0);
        if (top !== atTop) { atTop = top; post({ type: 'top', top }); }
      };
      document.addEventListener('scroll', (e) => {
        const t = e.target;
        lastScroller = (t && t.nodeType === 1 && t !== document.documentElement && t !== document.body) ? t : null;
        checkTop();
      }, { capture: true, passive: true });

      let playing = false;
      const media = () => {
        const now = [...document.querySelectorAll('video, audio')].some(m =>
          !m.paused && !m.ended && m.readyState > 2 && m.volume > 0 && (!m.muted || window.__lumenMuted));
        if (now !== playing) { playing = now; post({ type: 'media', playing: now }); }
      };
      for (const ev of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) {
        document.addEventListener(ev, (e) => {
          if (window.__lumenMuted && (ev === 'play' || ev === 'playing') && e.target) e.target.muted = true;
          media();
        }, true);
      }
      window.__lumenSetMuted = (m) => {
        window.__lumenMuted = m;
        document.querySelectorAll('video, audio').forEach(v => { v.muted = m; });
        media();
      };
    })();
    """#

    // MARK: Logins: find sign-in fields, offer saved accounts, fill them, and notice submitted credentials

    static let logins = #"""
    (() => {
      if (window.__lumenLogins) return;
      window.__lumenLogins = true;
      const post = (m) => { try { webkit.messageHandlers.lumen.postMessage(m); } catch (e) {} };
      const visible = (el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
      };
      const textual = (i) => i instanceof HTMLInputElement && /^(text|email|tel|)$/.test(i.type);
      const userish = (i) => textual(i) && (i.type === 'email' ||
        /user|email|e-mail|login|account|identifier|mail|phone/i.test([i.autocomplete, i.name, i.id, i.placeholder, i.getAttribute('aria-label')].join(' ')));
      const fields = (anchor) => {
        const scope = (anchor && anchor.form) || document;
        const pw = [...scope.querySelectorAll('input[type=password]')].filter(visible)[0] || null;
        let user = scope.querySelector('input[autocomplete~=username], input[autocomplete~=email]');
        if (!user || !visible(user)) {
          const inputs = [...scope.querySelectorAll('input')].filter((i) => visible(i) && textual(i));
          const before = pw ? inputs.filter((i) => i.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING) : inputs.filter(userish);
          user = before.reverse().find(userish) || before[0] || null;
        }
        return { user, pw };
      };

      // Only tells Lumen when a menu may be showing, so scrolling doesn't send a message every frame.
      let menuOpen = false;
      document.addEventListener('focusin', (e) => {
        const t = e.target;
        if (!(t instanceof HTMLInputElement)) return;
        const f = fields(t);
        const isPw = t.type === 'password';
        if (!isPw && !(f.pw && t === f.user) && !(!f.pw && userish(t) && /username|email/.test(t.autocomplete || ''))) return;
        if (isPw && location.protocol === 'http:') post({ type: 'insecurePassword' });
        const r = t.getBoundingClientRect();
        const scope = t.form || document;
        const isNew = isPw && (/new-password/.test(t.autocomplete || '') ||
          [...scope.querySelectorAll('input[type=password]')].filter(visible).length > 1 ||
          /sign.?up|register|create|join|iscri|registra|inscri|nuova password|new password|nouveau mot/i.test(
            [scope.action || '', scope.id || '', scope.className || '', t.name, t.id, t.placeholder].join(' ')));
        post({ type: 'loginFocus', x: r.left, y: r.bottom, w: r.width, newPassword: isNew });
        menuOpen = true;
      }, true);
      const hide = () => { if (menuOpen) { menuOpen = false; post({ type: 'loginBlur' }); } };
      document.addEventListener('mousedown', (e) => { if (!(e.target instanceof HTMLInputElement)) hide(); }, true);
      window.addEventListener('scroll', hide, { passive: true, capture: true });

      let last = '';
      const capture = (anchor) => {
        const f = fields(anchor);
        if (!f.pw || !f.pw.value) {
          if (f.user && f.user.value && userish(f.user)) post({ type: 'loginUsername', username: f.user.value });
          return;
        }
        const key = (f.user ? f.user.value : '') + '\u0001' + f.pw.value;
        if (key === last) return;
        last = key;
        post({ type: 'loginSubmit', username: f.user ? f.user.value : '', password: f.pw.value });
      };
      document.addEventListener('submit', (e) => capture(e.target.querySelector('input')), true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target instanceof HTMLInputElement) capture(e.target);
      }, true);
      document.addEventListener('click', (e) => {
        const b = e.target.closest && e.target.closest('button, input[type=submit], [role=button]');
        if (!b) return;
        const label = [b.textContent, b.value, b.getAttribute('aria-label')].join(' ');
        if (b.type === 'submit' || /log\s?in|sign\s?in|accedi|entra|connexion|connecter|continu|next|avanti|suivant|submit/i.test(label)) {
          capture(b.form ? b.form.querySelector('input') : document.activeElement);
        }
      }, true);

      window.__lumenFillNew = (password) => {
        const anchor = document.activeElement instanceof HTMLInputElement ? document.activeElement : null;
        const scope = (anchor && anchor.form) || document;
        const fields = [...scope.querySelectorAll('input[type=password]')].filter(visible)
          .filter((p) => !/current-password/.test(p.autocomplete || ''));
        for (const el of fields) {
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, password);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        return fields.length;
      };

      window.__lumenFill = (username, password) => {
        const anchor = document.activeElement instanceof HTMLInputElement ? document.activeElement : null;
        const f = fields(anchor);
        const set = (el, v) => {
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        };
        const user = f.user || (anchor && textual(anchor) ? anchor : null);
        if (user && username) set(user, username);
        if (f.pw) { set(f.pw, password); f.pw.focus(); }
        return !!(f.pw || user);
      };
    })();
    """#

    // MARK: HTTPS-only interstitial

    static func httpsOnlyPage(url: URL) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let host = url.host ?? url.absoluteString
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(L("Not Secure")))</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; height: 100vh; display: flex; align-items: center; justify-content: center;
               font: 15px -apple-system, sans-serif; color: #6e6e73; background: Canvas; }
        .box { max-width: 480px; text-align: center; padding: 24px; }
        .icon { font-size: 44px; margin-bottom: 14px; }
        h1 { color: CanvasText; font-size: 24px; font-weight: 600; margin: 0 0 10px; }
        p { line-height: 1.5; margin: 0 0 24px; }
        a { display: inline-block; padding: 8px 18px; border-radius: 8px; text-decoration: none; font-weight: 500; margin: 0 4px; }
        .back { background: #5e5ce6; color: white; }
        .go { color: #d9534f; }
        </style></head><body><div class="box"><div class="icon">🔒</div>
        <h1>\(esc(L("This site doesn't support a secure connection")))</h1>
        <p>\(esc(String(format: L("HTTPS-only mode is on. %@ only works over HTTP, so anyone on your network could see or change what you send."), host)))</p>
        <a class="back" href="javascript:history.back()">\(esc(L("Go Back")))</a>
        <a class="go" href="lumen-continue-http:\(esc(url.absoluteString))">\(esc(L("Continue to Site")))</a>
        </div></body></html>
        """
    }

    // MARK: Global Privacy Control

    static let gpc = #"""
    (() => {
      try {
        Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', { get: () => true, configurable: true });
      } catch (e) {}
    })();
    """#

    // MARK: Cookie banners

    static let cookieBanners = #"""
    (() => {
      const allow = __ALLOW__;
      const h = location.hostname;
      if (allow.some(d => h === d || h.endsWith('.' + d))) return;
      const sel = [
        '#onetrust-banner-sdk', '#onetrust-consent-sdk', '.onetrust-pc-dark-filter', '#CybotCookiebotDialog',
        '#CybotCookiebotDialogBodyUnderlay', '#usercentrics-root', '#usercentrics-cmp-ui', '#didomi-host',
        '.qc-cmp2-container', '#qc-cmp2-container', '.fc-consent-root', '#cmpbox', '#cmpbox2', '.cmpboxBG',
        '#truste-consent-track', '#consent_blackbar', '.truste_overlay', '.truste_box_overlay', '.osano-cm-window',
        '.osano-cm-dialog', '#cookie-law-info-bar', '.cli-modal-backdrop', '.cc-window', '.cc-banner',
        '#cookiescript_injected', '#iubenda-cs-banner', '#hs-eu-cookie-confirmation', '#BorlabsCookieBox',
        '#moove_gdpr_cookie_info_bar', '#tarteaucitronRoot', '#axeptio_overlay', '.klaro', '#klaro',
        '[id^="sp_message_container_"]', '#sp-cc', '#gdpr-cookie-message', '#cookie-banner', '.cookie-banner',
        '#cookie-notice', '.cookie-notice', '#cookieConsent', '.cookie-consent', '#cookie-consent',
        '.evidon-banner', '#_evidon_banner', '#termly-code-snippet-support', '.cky-consent-container', '.cky-overlay',
        '#ccc', '.ch2-container', '#cmp-app-container', '.cmp-root', '#gdpr-consent-tool-wrapper',
      ].join(',');
      const style = document.createElement('style');
      style.textContent = sel + '{display:none!important;visibility:hidden!important}';
      (document.head || document.documentElement).appendChild(style);
      const unlock = () => {
        if (!document.querySelector(sel)) return;
        for (const el of [document.documentElement, document.body]) {
          if (!el) continue;
          if (getComputedStyle(el).overflow === 'hidden' || getComputedStyle(el).overflowY === 'hidden') {
            el.style.setProperty('overflow', 'auto', 'important');
          }
          el.classList.remove('didomi-popup-open', 'sp-message-open', 'qc-cmp-ui-showing', 'cmp-open', 'no-scroll');
        }
      };
      document.addEventListener('DOMContentLoaded', unlock);
      window.addEventListener('load', unlock);
      setTimeout(unlock, 1500);
      setTimeout(unlock, 4000);
    })();
    """#

    // MARK: YouTube ads

    static let youtube = #"""
    (() => {
      const h = location.hostname;
      if (!/(^|\.)youtube\.com$/.test(h)) return;
      const allow = __ALLOW__;
      if (allow.some(d => h === d || h.endsWith('.' + d))) return;

      const keys = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams'];
      const strip = (o) => {
        if (!o || typeof o !== 'object') return o;
        for (const k of keys) if (k in o) delete o[k];
        if (o.playerResponse) strip(o.playerResponse);
        return o;
      };
      const parse = JSON.parse;
      JSON.parse = function () { return strip(parse.apply(this, arguments)); };
      const json = Response.prototype.json;
      Response.prototype.json = function () { return json.call(this).then(strip); };
      let ipr;
      try {
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
          configurable: true, get: () => ipr, set: (v) => { ipr = strip(v); },
        });
      } catch (e) {}

      // Anything that still slips through is fast-forwarded. The player is watched for its
      // 'ad-showing' class instead of polling, so idle and background tabs cost nothing.
      const skip = (player) => {
        if (!player.classList.contains('ad-showing')) return;
        document.querySelectorAll('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button').forEach(b => b.click());
        const v = player.querySelector('video');
        if (v && isFinite(v.duration) && v.duration > 0) v.currentTime = v.duration;
      };
      let current = null;
      const watch = () => {
        if (current && current.isConnected) return;
        const player = document.querySelector('.html5-video-player');
        if (!player || player === current) return;
        current = player;
        new MutationObserver(() => skip(player)).observe(player, { attributes: true, attributeFilter: ['class'] });
        // Skip buttons and the ad's length can arrive after the class does.
        player.addEventListener('loadedmetadata', () => skip(player), true);
        player.addEventListener('timeupdate', () => skip(player), true);
        skip(player);
      };
      new MutationObserver(watch).observe(document, { childList: true, subtree: true });

      const css = [
        'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer', 'ytd-banner-promo-renderer',
        'ytd-promoted-sparkles-web-renderer', 'ytd-display-ad-renderer', 'ytd-companion-slot-renderer',
        'ytd-action-companion-ad-renderer', 'ytd-player-legacy-desktop-watch-ads-renderer', '#player-ads',
        '#masthead-ad', '.ytp-ad-overlay-container', 'ytd-statement-banner-renderer',
        'ytd-rich-item-renderer:has(ytd-ad-slot-renderer)', 'ytd-rich-section-renderer:has(ytd-statement-banner-renderer)',
      ].join(',') + '{display:none!important}';
      const add = () => {
        const s = document.createElement('style');
        s.textContent = css;
        (document.head || document.documentElement).appendChild(s);
      };
      if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add);
    })();
    """#

    // MARK: Force dark

    static let forceDark = #"""
    (() => {
      const s = document.createElement('style');
      s.id = 'lumen-dark';
      s.textContent = 'html{filter:invert(.92) hue-rotate(180deg)!important;background:#fff!important}' +
        'img,video,picture,canvas,iframe,embed,object,[style*="background-image"]{filter:invert(1) hue-rotate(180deg)!important}';
      document.documentElement.appendChild(s);
      const dark = (el) => {
        if (!el) return null;
        const m = getComputedStyle(el).backgroundColor.match(/rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?/);
        if (!m || (m[4] !== undefined && parseFloat(m[4]) < 0.5)) return null;
        return (0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3]) / 255 < 0.4;
      };
      document.addEventListener('DOMContentLoaded', () => {
        s.disabled = true;
        const meta = document.querySelector('meta[name="color-scheme"]');
        const isDark = dark(document.body) ?? dark(document.documentElement) ?? (meta && /^\s*dark/.test(meta.content));
        if (isDark) s.remove(); else s.disabled = false;
      });
    })();
    """#

    // MARK: Site styles

    static let siteStyles = #"""
    (() => {
      const rules = __RULES__;
      const h = location.hostname.toLowerCase();
      const css = rules.filter(r => h === r.host || h.endsWith('.' + r.host)).map(r => r.css).join('\n');
      if (!css) return;
      const s = document.createElement('style');
      s.id = 'lumen-site-style';
      s.textContent = css;
      (document.head || document.documentElement).appendChild(s);
    })();
    """#

    // MARK: Reader

    /// Extracts the main article; returns {title, site, byline, html, words} or null.
    static let reader = #"""
    (() => {
      const pick = () => {
        const arts = [...document.querySelectorAll('article, [itemprop="articleBody"], main')];
        const best = arts.sort((a, b) => b.innerText.length - a.innerText.length)[0];
        if (best && best.innerText.length > 800) return best;
        let el = null, top = 0;
        for (const c of document.querySelectorAll('div, section')) {
          let n = 0;
          for (const p of c.children) if (p.tagName === 'P') n += p.innerText.length;
          if (n > top) { top = n; el = c; }
        }
        return top > 500 ? el : null;
      };
      const root = pick();
      if (!root) return null;
      const keep = new Set(['P','H1','H2','H3','H4','H5','BLOCKQUOTE','PRE','CODE','UL','OL','LI','FIGURE','FIGCAPTION',
        'IMG','A','EM','STRONG','B','I','U','BR','HR','TABLE','THEAD','TBODY','TR','TD','TH','SUP','SUB','DL','DT','DD']);
      const drop = new Set(['SCRIPT','STYLE','NOSCRIPT','IFRAME','FORM','BUTTON','INPUT','NAV','ASIDE','FOOTER','SVG','CANVAS','VIDEO','AUDIO','SELECT','TEXTAREA']);
      const junk = /(share|social|related|promo|advert|newsletter|comment|subscribe|sidebar|cookie|banner|popup|footer|byline-share|recirc)/i;
      const clone = (node) => {
        if (node.nodeType === 3) return document.createTextNode(node.textContent);
        if (node.nodeType !== 1 || drop.has(node.tagName)) return null;
        const id = (typeof node.className === 'string' ? node.className : '') + ' ' + (node.id || '');
        if (junk.test(id) && node !== root) return null;
        if (node.tagName === 'IMG') {
          const src = node.currentSrc || node.src || node.dataset.src || node.dataset.lazySrc;
          if (!src || node.width && node.width < 80) return null;
          const img = document.createElement('img');
          img.src = src;
          img.alt = node.alt || '';
          return img;
        }
        const out = keep.has(node.tagName) ? document.createElement(node.tagName) : document.createDocumentFragment();
        if (node.tagName === 'A' && node.href) out.setAttribute('href', node.href);
        for (const c of node.childNodes) { const k = clone(c); if (k) out.appendChild(k); }
        return out;
      };
      const box = document.createElement('div');
      box.appendChild(clone(root));
      const meta = (n) => { const m = document.querySelector(`meta[property="${n}"], meta[name="${n}"]`); return m ? m.content : ''; };
      const title = meta('og:title') || document.title;
      const h1 = box.querySelector('h1');
      if (h1 && h1.textContent.trim() === title.trim()) h1.remove();
      return {
        title, byline: meta('author'), site: meta('og:site_name') || location.hostname.replace(/^www\./, ''),
        html: box.innerHTML, words: root.innerText.split(/\s+/).length,
      };
    })();
    """#

    static func readerPage(title: String, site: String, byline: String, html: String, minutes: Int) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let meta = [site, byline, String(format: L("%lld min read"), minutes)].filter { !$0.isEmpty }.map(esc).joined(separator: " · ")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>\(esc(title))</title>
        <style>
        :root { color-scheme: light dark; --bg: #fbfaf7; --fg: #1d1d1f; --muted: #6e6e73; --link: #3a5bd9; --rule: #e5e2db; }
        @media (prefers-color-scheme: dark) { :root { --bg: #1b1b1d; --fg: #e8e6e3; --muted: #9a9a9f; --link: #8fa8ff; --rule: #333; } }
        html { background: var(--bg); }
        body { margin: 0 auto; max-width: 680px; padding: 72px 28px 120px; color: var(--fg);
               font: 20px/1.7 "New York", ui-serif, Georgia, serif; -webkit-font-smoothing: antialiased; }
        header { margin-bottom: 40px; border-bottom: 1px solid var(--rule); padding-bottom: 24px; }
        h1.title { font: 700 38px/1.2 -apple-system, ui-sans-serif, sans-serif; letter-spacing: -0.02em; margin: 0 0 12px; }
        .meta { font: 14px -apple-system, sans-serif; color: var(--muted); }
        h2, h3, h4 { font-family: -apple-system, ui-sans-serif, sans-serif; line-height: 1.3; margin-top: 1.8em; }
        img { max-width: 100%; height: auto; border-radius: 8px; display: block; margin: 1.5em auto; }
        figcaption { font: 14px -apple-system, sans-serif; color: var(--muted); text-align: center; }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        blockquote { margin: 1.5em 0; padding-left: 1.2em; border-left: 3px solid var(--rule); color: var(--muted); }
        pre, code { font: 15px ui-monospace, Menlo, monospace; } pre { overflow-x: auto; padding: 16px; background: rgba(127,127,127,.1); border-radius: 8px; }
        table { border-collapse: collapse; width: 100%; font-size: 16px; } td, th { border: 1px solid var(--rule); padding: 6px 10px; }
        </style></head><body>
        <header><h1 class="title">\(esc(title))</h1><div class="meta">\(meta)</div></header>
        <article>\(html)</article>
        </body></html>
        """
    }

    // MARK: Error page

    static func errorPage(url: URL, error: NSError) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let offline = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed].contains(error.code)
        let title = L(offline ? "You're offline" : (error.code == NSURLErrorCannotFindHost ? "Can't find this site" : "Can't open this page"))
        let host = url.host ?? url.absoluteString
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; height: 100vh; display: flex; align-items: center; justify-content: center;
               font: 15px -apple-system, sans-serif; color: #6e6e73; background: Canvas; }
        .box { max-width: 460px; text-align: center; padding: 24px; }
        .orb { width: 56px; height: 56px; border-radius: 50%; margin: 0 auto 24px;
               background: radial-gradient(circle at 40% 35%, #fff, #ffd98a 60%, #f0a830); box-shadow: 0 0 40px #ffd68a88; }
        h1 { color: CanvasText; font-size: 24px; font-weight: 600; margin: 0 0 10px; }
        p { line-height: 1.5; margin: 0 0 24px; }
        a.btn { display: inline-block; padding: 8px 18px; border-radius: 8px; background: #5e5ce6; color: white; text-decoration: none; font-weight: 500; }
        code { font-size: 12px; opacity: .7; }
        </style></head><body><div class="box"><div class="orb"></div>
        <h1>\(esc(title))</h1>
        <p>\(esc(error.localizedDescription))<br><strong>\(esc(host))</strong></p>
        <a class="btn" href="\(esc(url.absoluteString))">\(esc(L("Try Again")))</a>
        <p><code>\(esc(error.domain)) \(error.code)</code></p>
        </div></body></html>
        """
    }
}

/// Receives messages from the bridge script and routes them to the tab that sent them.
final class ScriptBridge: NSObject, WKScriptMessageHandler {
    static let shared = ScriptBridge()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let tab = Tab.owner(of: webView),
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        tab.handleMessage(type, body)
    }
}
