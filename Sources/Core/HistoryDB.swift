import Foundation
import SQLite3

/// History on disk as SQLite, so a visit writes one row instead of rewriting the whole history.
/// Writes go through a serial queue in the background; `flush` waits for them.
final class HistoryDB {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "lumen.history", qos: .utility)
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(_ url: URL) {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("CREATE TABLE IF NOT EXISTS visits (id TEXT PRIMARY KEY, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL, date REAL NOT NULL, visits INTEGER NOT NULL)")
        exec("CREATE INDEX IF NOT EXISTS visits_date ON visits(date)")
    }

    deinit { sqlite3_close(db) }

    /// Every entry, newest first.
    func load() -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        query("SELECT id, url, title, date, visits FROM visits ORDER BY date DESC", []) { s in
            guard let idText = Self.text(s, 0), let id = UUID(uuidString: idText),
                  let urlText = Self.text(s, 1), let url = URL(string: urlText) else { return }
            out.append(HistoryEntry(id: id, url: url, title: Self.text(s, 2) ?? "",
                                    date: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                                    visits: Int(sqlite3_column_int64(s, 4))))
        }
        return out
    }

    var isEmpty: Bool {
        var empty = true
        query("SELECT 1 FROM visits LIMIT 1", []) { _ in empty = false }
        return empty
    }

    /// Inserts or replaces entries; an entry replaces any row with the same id or URL.
    func save(_ entries: [HistoryEntry]) {
        guard !entries.isEmpty else { return }
        queue.async { [self] in
            transaction {
                for e in entries {
                    run("INSERT OR REPLACE INTO visits (id, url, title, date, visits) VALUES (?, ?, ?, ?, ?)",
                        [e.id.uuidString, e.url.absoluteString, e.title, e.date.timeIntervalSince1970, e.visits])
                }
            }
        }
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        queue.async { [self] in
            transaction { for id in ids { run("DELETE FROM visits WHERE id = ?", [id.uuidString]) } }
        }
    }

    /// Clears everything, or what was visited since `date`. Waits until it's done, so nothing is left behind if Lumen quits.
    func clear(since date: Date?) {
        queue.sync {
            if let date { run("DELETE FROM visits WHERE date >= ?", [date.timeIntervalSince1970]) } else { run("DELETE FROM visits", []) }
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Waits for pending writes.
    func flush() { queue.sync {} }

    // MARK: SQLite helpers

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func transaction(_ body: () -> Void) {
        exec("BEGIN")
        body()
        exec("COMMIT")
    }

    private func bind(_ stmt: OpaquePointer, _ values: [Any]) {
        for (i, v) in values.enumerated() {
            let n = Int32(i + 1)
            switch v {
            case let s as String: sqlite3_bind_text(stmt, n, s, -1, Self.transient)
            case let d as Double: sqlite3_bind_double(stmt, n, d)
            case let i as Int: sqlite3_bind_int64(stmt, n, Int64(i))
            default: sqlite3_bind_null(stmt, n)
            }
        }
    }

    private func run(_ sql: String, _ values: [Any]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        sqlite3_step(stmt)
    }

    private func query(_ sql: String, _ values: [Any], _ row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(stmt, i).map { String(cString: $0) }
    }
}
