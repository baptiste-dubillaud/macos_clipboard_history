//
//  ClipboardRepository.swift
//  ClipboardEnhanced
//
//  Persistance de l'historique (SQLite). Source de vérité durable.
//

import Foundation

/// CRUD de l'historique au-dessus de `Database`.
///
/// Le schéma prévoit dès maintenant les colonnes image/fichier (`data`,
/// `thumbnail`, `bookmark`, `file_path`) pour éviter une migration en phase 5.
/// En phase 2, seules les colonnes texte sont alimentées.
@MainActor
final class ClipboardRepository {
    private let db: Database

    init() throws {
        let url = try Self.databaseURL()
        db = try Database(path: url.path)
        try migrate()
    }

    // MARK: - Emplacement

    private static func databaseURL() throws -> URL {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("ClipboardEnhanced", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlite")
    }

    // MARK: - Migrations

    private func migrate() throws {
        if try db.userVersion() < 1 {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS clipboard_item (
                    id             TEXT PRIMARY KEY,
                    type           TEXT NOT NULL,
                    text           TEXT NOT NULL DEFAULT '',
                    data           BLOB,
                    thumbnail      BLOB,
                    bookmark       BLOB,
                    file_path      TEXT,
                    content_hash   TEXT NOT NULL,
                    created_at     REAL NOT NULL,
                    last_copied_at REAL NOT NULL,
                    is_pinned      INTEGER NOT NULL DEFAULT 0
                );
            """)
            try db.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_content_hash ON clipboard_item(content_hash);"
            )
            try db.execute(
                "CREATE INDEX IF NOT EXISTS idx_last_copied ON clipboard_item(last_copied_at);"
            )
            try db.setUserVersion(1)
        }
    }

    // MARK: - Lecture

    /// Tous les éléments, épinglés d'abord puis du plus récent au plus ancien.
    ///
    /// Ne charge **pas** les images pleines (`data`) pour rester léger en mémoire :
    /// seules les vignettes le sont. La donnée pleine se charge via `imageData(id:)`.
    func fetchAll() throws -> [ClipboardItem] {
        let statement = try db.prepare("""
            SELECT id, type, text, thumbnail, file_path, created_at, last_copied_at, is_pinned, content_hash
            FROM clipboard_item
            ORDER BY is_pinned DESC, last_copied_at DESC;
        """)
        var items: [ClipboardItem] = []
        while try statement.step() {
            let path = statement.string(4)
            items.append(ClipboardItem(
                id: UUID(uuidString: statement.string(0)) ?? UUID(),
                type: ClipboardItemType(rawValue: statement.string(1)) ?? .text,
                text: statement.string(2),
                createdAt: Date(timeIntervalSince1970: statement.double(5)),
                lastCopiedAt: Date(timeIntervalSince1970: statement.double(6)),
                isPinned: statement.int(7) != 0,
                imageData: nil,
                thumbnailData: statement.blob(3),
                filePath: path.isEmpty ? nil : path,
                contentHash: statement.string(8)
            ))
        }
        return items
    }

    /// Charge à la demande la donnée image pleine d'un élément.
    func imageData(id: UUID) throws -> Data? {
        let statement = try db.prepare("SELECT data FROM clipboard_item WHERE id = ?;")
        statement.bind(1, id.uuidString)
        return try statement.step() ? statement.blob(0) : nil
    }

    // MARK: - Écriture

    /// Insère un nouvel élément. Le dédoublonnage est décidé en amont par le store
    /// (l'index unique sur `content_hash` reste un garde-fou).
    func insert(_ item: ClipboardItem) throws {
        let statement = try db.prepare("""
            INSERT OR IGNORE INTO clipboard_item
                (id, type, text, data, thumbnail, file_path, content_hash, created_at, last_copied_at, is_pinned)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        statement
            .bind(1, item.id.uuidString)
            .bind(2, item.type.rawValue)
            .bind(3, item.text)
            .bind(4, item.imageData)
            .bind(5, item.thumbnailData)
            .bind(6, item.filePath)
            .bind(7, item.contentHash)
            .bind(8, item.createdAt.timeIntervalSince1970)
            .bind(9, item.lastCopiedAt.timeIntervalSince1970)
            .bind(10, Int32(item.isPinned ? 1 : 0))
        try statement.step()
    }

    /// Met à jour la date de dernière copie (dédoublonnage).
    func touch(id: UUID, date: Date) throws {
        let statement = try db.prepare(
            "UPDATE clipboard_item SET last_copied_at = ? WHERE id = ?;"
        )
        statement.bind(1, date.timeIntervalSince1970).bind(2, id.uuidString)
        try statement.step()
    }

    /// Met à jour le libellé/texte cherchable (ex. après OCR d'une image).
    func updateText(id: UUID, text: String) throws {
        let statement = try db.prepare("UPDATE clipboard_item SET text = ? WHERE id = ?;")
        statement.bind(1, text).bind(2, id.uuidString)
        try statement.step()
    }

    func setPinned(id: UUID, pinned: Bool) throws {
        let statement = try db.prepare(
            "UPDATE clipboard_item SET is_pinned = ? WHERE id = ?;"
        )
        statement.bind(1, Int32(pinned ? 1 : 0)).bind(2, id.uuidString)
        try statement.step()
    }

    func delete(id: UUID) throws {
        let statement = try db.prepare("DELETE FROM clipboard_item WHERE id = ?;")
        statement.bind(1, id.uuidString)
        try statement.step()
    }

    // MARK: - Rétention

    /// Purge les éléments **non épinglés** : ceux plus vieux que `cutoff`,
    /// puis tout ce qui dépasse les `keepingNewest` plus récents.
    /// Les éléments épinglés sont toujours conservés.
    func purge(olderThan cutoff: Date, keepingNewest maxCount: Int) throws {
        let byAge = try db.prepare(
            "DELETE FROM clipboard_item WHERE is_pinned = 0 AND last_copied_at < ?;"
        )
        byAge.bind(1, cutoff.timeIntervalSince1970)
        try byAge.step()

        let byCount = try db.prepare("""
            DELETE FROM clipboard_item
            WHERE is_pinned = 0 AND id NOT IN (
                SELECT id FROM clipboard_item
                WHERE is_pinned = 0
                ORDER BY last_copied_at DESC
                LIMIT ?
            );
        """)
        byCount.bind(1, Int32(max(0, maxCount)))
        try byCount.step()
    }
}
