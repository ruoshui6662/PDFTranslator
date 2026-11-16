import Foundation
import CryptoKit
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor TranslationCache {
    public static let shared = TranslationCache()

    nonisolated(unsafe) private var db: OpaquePointer?
    public let databaseURL: URL

    /// 缓存条目留存时长：默认 6 小时，过期自动清理
    public var cacheExpirationInterval: TimeInterval = 6 * 3600

    public init(databaseURL: URL? = nil) {
        if let customURL = databaseURL {
            self.databaseURL = customURL
        } else {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let appCacheDir = cachesDir.appendingPathComponent("com.pdftranslator.app", isDirectory: true)
            try? FileManager.default.createDirectory(at: appCacheDir, withIntermediateDirectories: true)
            self.databaseURL = appCacheDir.appendingPathComponent("translation_cache.sqlite3")
        }
        var handle: OpaquePointer?
        let dir = self.databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if sqlite3_open(self.databaseURL.path, &handle) == SQLITE_OK, let handle {
            self.db = handle
            let createTableSQL = """
            CREATE TABLE IF NOT EXISTS translations (
                cache_key TEXT PRIMARY KEY,
                translated_text TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """
            sqlite3_exec(handle, createTableSQL, nil, nil, nil)
        }
        // 启动时清理已过期缓存条目
        expireEntriesOlderThan(cacheExpirationInterval)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public static func makeKey(
        engineID: String,
        model: String,
        promptVersion: String = TranslationPromptBuilder.promptVersion,
        sourceLanguage: Locale.Language,
        targetLanguage: Locale.Language,
        sourceText: String
    ) -> String {
        let langPair = "\(sourceLanguage.minimalIdentifier)->\(targetLanguage.minimalIdentifier)"
        let raw = "\(engineID)|\(model)|\(promptVersion)|\(langPair)|\(sourceText)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func get(forKey key: String) -> String? {
        guard let db else { return nil }
        let sql = "SELECT translated_text FROM translations WHERE cache_key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        if sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) {
            return String(cString: cStr)
        }
        return nil
    }

    public func set(_ translatedText: String, forKey key: String) {
        guard let db else { return }
        let sql = """
        INSERT INTO translations (cache_key, translated_text, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(cache_key) DO UPDATE SET
            translated_text = excluded.translated_text,
            updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, translatedText, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    public func count() -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM translations;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    public func remove(forKey key: String) {
        guard let db else { return }
        let sql = "DELETE FROM translations WHERE cache_key = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_step(stmt)
    }

    public func clearAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM translations; VACUUM;", nil, nil, nil)
    }

    /// 删除 `olderThan` 秒之前未更新的缓存条目（供外部定时或主动触发清理）
    public nonisolated func expireEntriesOlderThan(_ olderThan: TimeInterval) {
        guard let db else { return }
        let cutoff = Date().timeIntervalSince1970 - olderThan
        let sql = "DELETE FROM translations WHERE updated_at < ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
    }
}
