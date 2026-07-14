//
//  ClipboardRepository.swift
//  ClipboardEnhanced
//
//  Persistance de l'historique (SQLite). Source de vérité durable.
//

import Foundation

/// CRUD de l'historique au-dessus de `Database`.
///
/// **Colonnes chiffrées** (AES-GCM, cf. `ContentCipher`) : `text`, `data`,
/// `thumbnail`, `file_path`, `embedding`. Restent en clair celles dont le moteur a
/// besoin pour trier et purger : `id`, `type`, les dates, `is_pinned`, et
/// `content_hash` — qui est un HMAC à clé, donc opaque sans la clé.
@MainActor
final class ClipboardRepository {
    private let db: Database
    private let cipher: ContentCipher

    init(cipher: ContentCipher) throws {
        self.cipher = cipher
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

    /// v3 : chiffrement au repos. Les colonnes sensibles passent de TEXT à BLOB, et
    /// l'ancien contenu **est détruit** — il a été écrit en clair, et sa réécriture
    /// chiffrée le laisserait de toute façon récupérable dans les pages libérées du
    /// fichier. Repartir d'un fichier neuf est la seule remise à zéro honnête.
    private func migrate() throws {
        let version = try db.userVersion()
        guard version < 3 else { return }

        try db.execute("DROP TABLE IF EXISTS clipboard_item;")
        try db.execute("""
            CREATE TABLE clipboard_item (
                id             TEXT PRIMARY KEY,
                type           TEXT NOT NULL,
                text           BLOB NOT NULL,
                data           BLOB,
                thumbnail      BLOB,
                file_path      BLOB,
                embedding      BLOB,
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
        // Réécrit le fichier pour que les anciennes pages en clair ne traînent plus.
        try db.execute("VACUUM;")
        try db.setUserVersion(3)
    }

    // MARK: - Lecture

    /// Tous les éléments, épinglés d'abord puis du plus récent au plus ancien.
    ///
    /// Ne charge **pas** les images pleines (`data`) pour rester léger en mémoire :
    /// seules les vignettes le sont. La donnée pleine se charge via `imageData(id:)`.
    func fetchAll() throws -> [ClipboardItem] {
        let statement = try db.prepare("""
            SELECT id, type, text, thumbnail, file_path, created_at, last_copied_at, is_pinned, content_hash, embedding
            FROM clipboard_item
            ORDER BY is_pinned DESC, last_copied_at DESC;
        """)
        var items: [ClipboardItem] = []
        while try statement.step() {
            guard let sealedText = statement.blob(2) else { continue }
            let embeddingData = try cipher.open(statement.blob(9))
            items.append(ClipboardItem(
                id: UUID(uuidString: statement.string(0)) ?? UUID(),
                type: ClipboardItemType(rawValue: statement.string(1)) ?? .text,
                text: try cipher.openString(sealedText),
                createdAt: Date(timeIntervalSince1970: statement.double(5)),
                lastCopiedAt: Date(timeIntervalSince1970: statement.double(6)),
                isPinned: statement.int(7) != 0,
                imageData: nil,
                thumbnailData: try cipher.open(statement.blob(3)),
                filePath: try cipher.openString(statement.blob(4)),
                embedding: embeddingData.map { VectorMath.vector(from: $0) },
                contentHash: statement.string(8)
            ))
        }
        return items
    }

    /// Charge à la demande la donnée image pleine d'un élément.
    func imageData(id: UUID) throws -> Data? {
        let statement = try db.prepare("SELECT data FROM clipboard_item WHERE id = ?;")
        statement.bind(1, id.uuidString)
        guard try statement.step() else { return nil }
        return try cipher.open(statement.blob(0))
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
            .bind(3, try cipher.seal(item.text))
            .bind(4, try cipher.seal(item.imageData))
            .bind(5, try cipher.seal(item.thumbnailData))
            .bind(6, try cipher.seal(item.filePath))
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
        statement.bind(1, try cipher.seal(text)).bind(2, id.uuidString)
        try statement.step()
    }

    /// Stocke le vecteur d'embedding d'un élément.
    ///
    /// Chiffré comme le reste : un vecteur sémantique reste une empreinte du contenu,
    /// et permettrait de tester si une phrase donnée est dans l'historique.
    func updateEmbedding(id: UUID, vector: [Float]) throws {
        let statement = try db.prepare("UPDATE clipboard_item SET embedding = ? WHERE id = ?;")
        statement.bind(1, try cipher.seal(VectorMath.data(from: vector))).bind(2, id.uuidString)
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
