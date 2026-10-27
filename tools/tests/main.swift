// Lumen's logic tests. Run with: tools/test.sh
// They use only pure functions and temporary files: nothing touches your Lumen data.
import Foundation
import WebKit

var failures = 0
var passed = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failures += 1; print("FAIL  \(name)  \(detail())") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) { check(a == b, name, "got \(a), want \(b)") }

// MARK: Address bar

func resolved(_ s: String) -> String? { InputResolver.resolve(s)?.absoluteString }

eq(resolved("reddit.com"), "https://reddit.com", "address: bare domain")
eq(resolved("  reddit.com  "), "https://reddit.com", "address: trims spaces")
eq(resolved("http://example.com"), "http://example.com", "address: keeps http")
eq(resolved("localhost:3000/x"), "http://localhost:3000/x", "address: localhost with port")
eq(resolved("192.168.1.10"), "http://192.168.1.10", "address: IP")
eq(resolved("bbc.co.uk/news"), "https://bbc.co.uk/news", "address: path")
check(resolved("reddit")?.contains("q=reddit") == true, "search: single word", resolved("reddit") ?? "nil")
check(resolved("how are you")?.contains("how%20are%20you") == true, "search: spaces encoded", resolved("how are you") ?? "nil")
check(resolved("c++ & rust")?.contains("c%2B%2B%20%26%20rust") == true, "search: + and & encoded", resolved("c++ & rust") ?? "nil")
check(resolved("yt lofi")?.hasPrefix("https://www.youtube.com/results?search_query=lofi") == true, "search shortcut", resolved("yt lofi") ?? "nil")
check(resolved("file.txt") != nil, "address: unknown TLD searches instead of failing")
eq(resolved(""), nil, "address: empty")
check(resolved("münchen.de") != nil, "address: international domain", "nil")
check(resolved("javascript:alert(1)").map { !$0.hasPrefix("javascript:") } ?? true, "address: javascript: is not opened as a page", resolved("javascript:alert(1)") ?? "")
eq(InputResolver.displayHost(URL(string: "https://www.apple.com/mac")), "apple.com", "display host strips www")
check(InputResolver.isInternational(URL(string: "https://xn--pple-43d.com")), "punycode warning")
check(!InputResolver.isInternational(URL(string: "https://apple.com")), "no warning for plain host")

// MARK: Link cleaning

eq(URLCleaner.clean(URL(string: "https://shop.example.com/item?id=42&utm_source=x&fbclid=y&gclid=z")!)?.absoluteString,
   "https://shop.example.com/item?id=42", "clean: tracking params")
eq(URLCleaner.clean(URL(string: "https://example.com/?id=1")!), nil, "clean: nothing to remove")
eq(URLCleaner.clean(URL(string: "https://example.com/?utm_medium=a")!)?.absoluteString, "https://example.com/", "clean: all params removed")
eq(URLCleaner.unwrap(URL(string: "https://www.google.com/url?q=https://example.com/a%3Futm_source%3Dx&sa=D")!)?.absoluteString,
   "https://example.com/a", "unwrap: google redirect")
eq(URLCleaner.unwrap(URL(string: "https://www.google.com/url?q=javascript:alert(1)")!), nil, "unwrap: refuses non-http targets")

// MARK: HTTPS upgrade

check(HTTPSUpgrade.eligible(URL(string: "http://example.com")!), "https: eligible")
check(!HTTPSUpgrade.eligible(URL(string: "http://localhost:8080")!), "https: not localhost")
check(!HTTPSUpgrade.eligible(URL(string: "http://192.168.0.1")!), "https: not IP")
check(!HTTPSUpgrade.eligible(URL(string: "https://example.com")!), "https: already https")
eq(HTTPSUpgrade.upgraded(URL(string: "http://example.com:80/a?b=1")!)?.absoluteString, "https://example.com/a?b=1", "https: drops port 80")

// MARK: Sites for passwords

let pslPairs = [("alice.github.io", "alice.github.io"), ("a.b.evil.github.io", "evil.github.io"), ("www.bbc.co.uk", "bbc.co.uk"),
                ("mail.google.com", "google.com"), ("foo.netlify.app", "foo.netlify.app"), ("localhost", "localhost"),
                ("192.168.1.10", "192.168.1.10"), ("accounts.example.com", "example.com"), ("WWW.Example.COM", "example.com"),
                ("github.io", "github.io"), ("a.b.ck", "a.b.ck"), ("www.ck", "www.ck")]
for (host, site) in pslPairs { eq(PasswordStore.site(host), site, "site(\(host))") }
check(PasswordStore.site("alice.github.io") != PasswordStore.site("evil.github.io"), "shared domain sites stay apart")

// MARK: CSV

eq(CSV.parse("a,b\n1,2\n"), [["a", "b"], ["1", "2"]], "csv: simple")
eq(CSV.parse("a,\"b,c\",\"d \"\"q\"\"\"\r\n"), [["a", "b,c", "d \"q\""]], "csv: quotes and CRLF")
eq(CSV.parse("x,\"multi\nline\"\n"), [["x", "multi\nline"]], "csv: newline inside quotes")
eq(CSV.parse(""), [], "csv: empty")
for s in ["plain", "a,b", "say \"hi\"", "two\nlines"] { eq(CSV.parse(CSV.escape(s) + "\n").first?.first, s, "csv: round trip \(s.debugDescription)") }

// MARK: Downloads

eq(DownloadManager.safeName("../../evil.command"), "evil.command", "download name: no parent path")
eq(DownloadManager.safeName("/etc/passwd"), "passwd", "download name: no absolute path")
eq(DownloadManager.safeName("a:b.txt"), "a-b.txt", "download name: colon")
eq(DownloadManager.safeName(".hidden"), "hidden", "download name: no hidden file")
eq(DownloadManager.safeName(""), nil, "download name: empty")
eq(DownloadManager.safeName("report.pdf"), "report.pdf", "download name: normal")
check(DownloadManager.isDangerous("Setup.PKG"), "dangerous: pkg, any case")
check(!DownloadManager.isDangerous("photo.jpg"), "not dangerous: jpg")

// MARK: Updates

eq(UpdateChecker.version(fromTag: "v1.5.4"), "1.5.4", "tag v1.5.4")
eq(UpdateChecker.version(fromTag: "v1.6-beta"), "1.6", "tag with suffix")
check(UpdateChecker.isNewer("1.6", than: "1.5.4"), "1.6 > 1.5.4")
check(UpdateChecker.isNewer("1.10", than: "1.9"), "1.10 > 1.9")
check(!UpdateChecker.isNewer("1.5", than: "1.5.0"), "1.5 == 1.5.0")
check(!UpdateChecker.isNewer("1.5.3", than: "1.5.4"), "1.5.3 < 1.5.4")

// MARK: AI providers

check(AIProvider.anthropic.guessesImages("claude-opus-5-5"), "vision: claude")
check(AIProvider.openAI.guessesImages("gpt-4o-mini"), "vision: gpt-4o")
check(!AIProvider.openAI.guessesImages("gpt-3.5-turbo"), "no vision: gpt-3.5")
check(AIProvider.deepSeek.guessesImages("DeepSeek-V4.1-Flash"), "vision: deepseek flash")
check(!AIProvider.deepSeek.guessesImages("deepseek-chat"), "no vision: deepseek-chat")
let userMsg = AssistantChat.userMessage(text: "hi", page: "<page>x</page>", images: [Data([1, 2])], provider: .anthropic)
check((userMsg["content"] as? [[String: Any]])?.first?["type"] as? String == "image", "anthropic image block")
let oaMsg = AssistantChat.userMessage(text: "hi", page: nil, images: [Data([1])], provider: .openAI)
check((oaMsg["content"] as? [[String: Any]])?.first?["type"] as? String == "image_url", "openai image block")
check(JSONSerialization.isValidJSONObject(userMsg) && JSONSerialization.isValidJSONObject(oaMsg), "messages encode as JSON")
for t in AssistantPrompt.tools { check(JSONSerialization.isValidJSONObject(AssistantPrompt.schema(t)), "tool schema \(t.name)") }

// MARK: Filter lists

let list = """
! comment
[Adblock Plus 2.0]
||ads.example.com^
||tracker.example.net^$third-party
@@||example.org/allowed^
example.com##.ad-banner
##.sponsored
example.com#@#.keep
/banner/*/img^
||ünicode.example^
"""
let out = FilterConverter.convert(list)
check(out.block.count >= 3, "filters: block rules", "\(out.block.count)")
eq(out.allow.count, 1, "filters: exception")
eq(out.hide.count, 2, "filters: cosmetic")
check(out.skipped >= 1, "filters: unsupported skipped")
check(JSONSerialization.isValidJSONObject(out.block + out.allow + out.hide), "filters: valid JSON")

// MARK: History database

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-tests-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
if let db = HistoryDB(tmp.appendingPathComponent("h.sqlite")) {
    check(db.isEmpty, "history: starts empty")
    let now = Date()
    let a = HistoryEntry(url: URL(string: "https://a.com")!, title: "A \"quoted\" ' title", date: now.addingTimeInterval(-10))
    let b = HistoryEntry(url: URL(string: "https://b.com")!, title: "B", date: now)
    db.save([a, b])
    db.flush()
    let loaded = db.load()
    eq(loaded.map(\.url.absoluteString), ["https://b.com", "https://a.com"], "history: newest first")
    eq(loaded.last?.title, a.title, "history: title with quotes survives")
    var a2 = a; a2.visits = 5; a2.date = now.addingTimeInterval(10)
    db.save([a2]); db.flush()
    eq(db.load().first?.visits, 5, "history: same URL replaced")
    eq(db.load().count, 2, "history: no duplicate URL")
    db.delete([b.id]); db.flush()
    eq(db.load().count, 1, "history: delete")
    db.save((0..<2000).map { HistoryEntry(url: URL(string: "https://x\($0).com")!, title: "\($0)", date: now) }); db.flush()
    eq(db.load().count, 2001, "history: 2000 rows in one transaction")
    db.clear(since: nil)
    check(db.isEmpty, "history: clear all")
    db.checkpoint()
    let wal = (try? FileManager.default.attributesOfItem(atPath: tmp.appendingPathComponent("h.sqlite-wal").path)[.size] as? Int) ?? 0
    eq(wal, 0, "history: WAL truncated by checkpoint")
} else {
    check(false, "history: database opens")
}
try? FileManager.default.removeItem(at: tmp)

// MARK: WebKit compiles the rules

func compiles(_ json: String, _ name: String) {
    let id = "lumen-test-\(UUID().uuidString)"
    var done = false
    WKContentRuleListStore.default().compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
        check(list != nil, "webkit compiles \(name)", error?.localizedDescription ?? "")
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in done = true }
    }
    let deadline = Date().addingTimeInterval(60)
    while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(done, "webkit finished \(name)")
}
compiles(BuiltInRules.json(), "built-in rules")
compiles(BuiltInRules.cookieJSON, "cookie rules")
let converted = String(decoding: try! JSONSerialization.data(withJSONObject: out.block + out.allow + out.hide), as: UTF8.self)
compiles(converted, "converted filters")

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
