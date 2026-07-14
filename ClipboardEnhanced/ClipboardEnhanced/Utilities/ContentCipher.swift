//
//  ContentCipher.swift
//  ClipboardEnhanced
//
//  Chiffrement des contenus persistés (AES-GCM) et empreinte de dédoublonnage (HMAC).
//

import CryptoKit
import Foundation

/// Chiffre/déchiffre les colonnes sensibles avec une clé symétrique de session.
///
/// AES-GCM est authentifié : une base modifiée hors de l'app fait échouer `open`
/// au lieu de renvoyer des octets silencieusement corrompus.
struct ContentCipher {
    enum Failure: Error {
        /// Le déchiffrement a échoué : mauvaise clé, ou donnée altérée.
        case corrupted
    }

    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    // MARK: - Chiffrement

    func seal(_ data: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key)
        // `combined` = nonce ‖ ciphertext ‖ tag : un seul BLOB à stocker.
        guard let combined = box.combined else { throw Failure.corrupted }
        return combined
    }

    func seal(_ text: String) throws -> Data {
        try seal(Data(text.utf8))
    }

    /// `nil` traverse le chiffrement (colonnes optionnelles : image, vignette, chemin).
    func seal(_ data: Data?) throws -> Data? {
        guard let data else { return nil }
        return try seal(data)
    }

    func seal(_ text: String?) throws -> Data? {
        guard let text else { return nil }
        return try seal(text)
    }

    // MARK: - Déchiffrement

    func open(_ data: Data) throws -> Data {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else {
            throw Failure.corrupted
        }
        return plain
    }

    func openString(_ data: Data) throws -> String {
        guard let text = String(data: try open(data), encoding: .utf8) else {
            throw Failure.corrupted
        }
        return text
    }

    func open(_ data: Data?) throws -> Data? {
        guard let data else { return nil }
        return try open(data)
    }

    func openString(_ data: Data?) throws -> String? {
        guard let data else { return nil }
        return try openString(data)
    }

    // MARK: - Empreinte

    /// Empreinte **à clé** (HMAC-SHA256) du contenu, pour le dédoublonnage.
    ///
    /// Un SHA-256 nu serait déterministe mais aussi *devinable* : l'empreinte d'un mot de
    /// passe court se retrouve par force brute en quelques secondes, alors même que le
    /// contenu est chiffré à côté. Le HMAC conserve le déterminisme (donc l'index unique
    /// et le dédoublonnage) sans rien révéler à qui n'a pas la clé.
    func fingerprint(_ content: CapturedContent) -> String {
        let basis: Data
        switch content.type {
        case .image: basis = content.imageData ?? Data()
        case .file:  basis = Data((content.filePath ?? "").utf8)
        case .text, .url: basis = Data(content.text.utf8)
        }

        var message = Data(content.type.rawValue.utf8)
        message.append(basis)

        let code = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}
