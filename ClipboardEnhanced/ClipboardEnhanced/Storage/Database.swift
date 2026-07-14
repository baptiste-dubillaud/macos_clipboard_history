//
//  Database.swift
//  ClipboardEnhanced
//
//  Wrapper minimal autour de la lib système SQLite3 (aucune dépendance externe).
//

import Foundation
import SQLite3

/// SQLite demande que les chaînes/blobs passés en `bind` soient copiés si on
/// réutilise le buffer Swift après l'appel : `SQLITE_TRANSIENT` force cette copie.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: Error {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
}

/// Connexion SQLite. Utilisée depuis le `@MainActor` (accès sérialisé, suffisant
/// pour un historique ≤ 200 éléments).
final class Database {
    private let handle: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "ouverture impossible"
            if let handle { sqlite3_close(handle) }
            throw DatabaseError.openFailed(message)
        }
        self.handle = handle
        // WAL : meilleures perfs en lecture/écriture concurrente, robustesse aux crashs.
        try? execute("PRAGMA journal_mode = WAL;")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Exécute une ou plusieurs instructions sans résultat (DDL, PRAGMA…).
    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "erreur SQL"
            sqlite3_free(errorPointer)
            throw DatabaseError.execFailed(message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        try Statement(handle: handle, sql: sql)
    }

    func userVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        return try statement.step() ? Int(statement.int(0)) : 0
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version);")
    }
}

/// Requête préparée. Les `bind` sont chaînables ; les `column*` lisent la ligne courante.
final class Statement {
    private let handle: OpaquePointer
    private let stmt: OpaquePointer

    init(handle: OpaquePointer, sql: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        self.handle = handle
        self.stmt = stmt
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    // MARK: - Bind (index commence à 1)

    @discardableResult
    func bind(_ index: Int32, _ value: String) -> Statement {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: String?) -> Statement {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Double) -> Statement {
        sqlite3_bind_double(stmt, index, value)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Int32) -> Statement {
        sqlite3_bind_int(stmt, index, value)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Data?) -> Statement {
        if let value {
            // SQLITE_TRANSIENT : SQLite copie les octets, sûr après la fin de la closure.
            // Code de retour ignoré, comme les autres `bind`.
            _ = value.withUnsafeBytes { buffer in
                sqlite3_bind_blob(stmt, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
        return self
    }

    // MARK: - Exécution

    /// Avance d'une ligne. Retourne `true` s'il y a une ligne, `false` à la fin.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:  return true
        case SQLITE_DONE: return false
        default:          throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    // MARK: - Lecture de colonnes (index commence à 0)

    func string(_ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }

    func double(_ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    func int(_ index: Int32) -> Int32 {
        sqlite3_column_int(stmt, index)
    }

    func blob(_ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: pointer, count: count)
    }
}
