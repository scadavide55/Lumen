import AVFoundation
import NaturalLanguage
import SwiftUI
import Translation
import WebKit

// MARK: - Translating pages on this Mac

/// Translates the page with Apple's Translation, on this Mac: nothing is sent anywhere. The page's text is swapped
/// in place, so links and layout keep working, and Show Original puts it back.
enum PageTranslator {
    /// Text nodes of the page, numbered, so their translations can go back to the same places.
    static let collectScript = """
    (() => {
      const skip = /^(SCRIPT|STYLE|NOSCRIPT|CODE|PRE|KBD|SAMP|TEXTAREA|INPUT|SELECT|SVG|MATH)$/;
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
        acceptNode(n) {
          for (let e = n.parentElement; e; e = e.parentElement) {
            if (skip.test(e.tagName) || e.isContentEditable || e.getAttribute('translate') === 'no') return NodeFilter.FILTER_REJECT;
          }
          return /\\p{L}{2}/u.test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
        }
      });
      const nodes = [];
      let total = 0;
      while (walker.nextNode() && nodes.length < 4000 && total < 150000) {
        nodes.push(walker.currentNode);
        total += walker.currentNode.nodeValue.length;
      }
      window.__tacetTranslation = { nodes, originals: nodes.map(n => n.nodeValue) };
      return nodes.map(n => n.nodeValue.trim());
    })()
    """

    static let applyScript = """
    const t = window.__tacetTranslation;
    if (!t) return false;
    texts.forEach((text, i) => {
      const n = t.nodes[i];
      if (!n || text == null) return;
      // Keeps the spaces around the text, which the layout depends on.
      const o = t.originals[i];
      n.nodeValue = o.match(/^\\s*/)[0] + text + o.match(/\\s*$/)[0];
    });
    return true;
    """

    static let restoreScript = """
    (() => {
      const t = window.__tacetTranslation;
      if (!t) return;
      t.nodes.forEach((n, i) => { n.nodeValue = t.originals[i]; });
      window.__tacetTranslation = null;
    })()
    """

    /// The language most of the page is in, so the translator knows what to translate from.
    static func language(of texts: [String]) -> Locale.Language? {
        let r = NLLanguageRecognizer()
        r.processString(texts.prefix(400).joined(separator: " "))
        return r.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    static var target: Locale.Language { Locale.Language(identifier: Locale.preferredLanguages.first ?? "en") }
}

/// Runs the translation the browser asks for. It sits invisibly in the window, since Apple's translator is only
/// handed out to views (and asks there to download a language the first time).
@available(macOS 15.0, *)
struct PageTranslationHost: View {
    @Environment(BrowserState.self) var b
    @State private var configuration: TranslationSession.Configuration?
    @State private var job: (tab: Tab, texts: [String])?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: b.translateRequest) { _, request in
                guard let request, let tab = b.tabs.first(where: { $0.id == request }) else { return }
                b.translateRequest = nil
                start(tab)
            }
            .translationTask(configuration) { session in
                guard let job else { return }
                do {
                    let requests = job.texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                    var out = [String?](repeating: nil, count: job.texts.count)
                    for r in try await session.translations(from: requests) {
                        if let i = r.clientIdentifier.flatMap(Int.init), i < out.count { out[i] = r.targetText }
                    }
                    guard let wv = job.tab.webView else { return }
                    _ = try await wv.callAsyncJavaScript(PageTranslator.applyScript, arguments: ["texts": out.map { $0.map { $0 as Any } ?? NSNull() }],
                                                         in: nil, contentWorld: .defaultClient)
                    job.tab.translatedFrom = session.sourceLanguage.flatMap { Locale.current.localizedString(forLanguageCode: $0.languageCode?.identifier ?? "") }
                        ?? L("another language")
                } catch {
                    job.tab.translationError = error.localizedDescription
                }
                job.tab.translating = false
                self.job = nil
            }
    }

    private func start(_ tab: Tab) {
        guard let wv = tab.webView, !tab.translating else { return }
        tab.translating = true
        tab.translationError = nil
        wv.evaluateJavaScript(PageTranslator.collectScript, in: nil, in: .defaultClient) { result in
            let texts = ((try? result.get()) as? [String]) ?? []
            guard !texts.isEmpty else { tab.translating = false; return }
            let source = PageTranslator.language(of: texts)
            let target = PageTranslator.target
            if let source, source.languageCode == target.languageCode {
                tab.translating = false
                tab.translationError = L("This page is already in your language.")
                return
            }
            job = (tab, texts)
            if configuration?.source == source && configuration?.target == target {
                configuration?.invalidate()
            } else {
                configuration = TranslationSession.Configuration(source: source, target: target)
            }
        }
    }
}

extension Tab {
    @MainActor
    func translatePage() {
        guard #available(macOS 15.0, *), url != nil else { NSSound.beep(); return }
        browser?.translateRequest = id
    }

    @MainActor
    func showOriginal() {
        webView?.evaluateJavaScript(PageTranslator.restoreScript, in: nil, in: .defaultClient)
        translatedFrom = nil
    }
}

/// "Translated from French · Show Original", above a translated page.
struct TranslationBar: View {
    var tab: Tab

    var body: some View {
        HStack(spacing: 8) {
            if tab.translating {
                ProgressView().controlSize(.small)
                Text("Translating on this Mac…")
            } else if let from = tab.translatedFrom {
                Image(systemName: "translate")
                Text(String(format: L("Translated from %@ on this Mac"), from))
                Spacer(minLength: 8)
                Button("Show Original") { tab.showOriginal() }.buttonStyle(.link)
            } else if let error = tab.translationError {
                Image(systemName: "exclamationmark.triangle")
                Text(error).lineLimit(2)
                Spacer(minLength: 8)
                Button("OK") { tab.translationError = nil }.buttonStyle(.link)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Reading aloud

/// Reads the Reader page aloud with the Mac's own voices, in the article's language.
@MainActor
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = ReadAloud()
    private let synth = AVSpeechSynthesizer()
    private(set) weak var tab: Tab?

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { synth.isSpeaking }

    func toggle(_ tab: Tab) {
        if synth.isSpeaking, self.tab === tab { stop(); return }
        stop()
        guard let wv = tab.webView else { return }
        // Reader's article, or the page's main text when Reader isn't on.
        let script = "(document.querySelector('article') || document.querySelector('main') || document.body).innerText"
        wv.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, let text = (try? result.get()) as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound.beep()
                return
            }
            let utterance = AVSpeechUtterance(string: String(text.prefix(200_000)))
            let r = NLLanguageRecognizer()
            r.processString(String(text.prefix(2000)))
            if let lang = r.dominantLanguage?.rawValue { utterance.voice = AVSpeechSynthesisVoice(language: lang) }
            self.tab = tab
            tab.readingAloud = true
            self.synth.speak(utterance)
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        tab?.readingAloud = false
        tab = nil
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.tab?.readingAloud = false; self.tab = nil }
    }
}
