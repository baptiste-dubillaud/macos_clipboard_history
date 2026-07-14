//
//  DatabaseKeyStore.swift
//  ClipboardEnhanced
//
//  Clé de chiffrement de la base, gardée dans le Trousseau de session.
//

import CryptoKit
import Foundation
import Security

/// Détient la clé maîtresse de la base dans le Trousseau de session.
///
/// **Sans verrou biométrique** : la clé est créée et relue en silence, l'app
/// démarre sans friction. Le Trousseau de session (« fichier », par opposition au
/// « data protection ») ne requiert **aucun entitlement** — donc pas de profil de
/// provisioning à renouveler. La clé reste protégée par l'ACL du Trousseau : une
/// autre app qui tente de la lire déclenche un consentement système.
///
/// Ce qui n'est **pas** couvert : quelqu'un physiquement devant la session
/// déverrouillée. Défendre ce cas exigerait le Trousseau data-protection (Touch ID)
/// et son entitlement ; décision produit : hors périmètre pour un presse-papier local.
///
/// `nonisolated` : type pur sans état partagé. Le projet isole tout au `MainActor` par
/// défaut ; on s'en affranchit pour que les appels Trousseau tournent hors du thread UI.
nonisolated enum DatabaseKeyStore {
    enum Failure: LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
                return "Trousseau : \(detail)"
            }
        }
    }

    private static let service = "com.bde.ClipboardEnhanced.databaseKey"
    private static let account = "master"
    private static let keyByteCount = 32  // AES-256

    /// Base de requête commune. `kSecUseDataProtectionKeychain = false` cible
    /// explicitement le Trousseau de session (celui qui ne demande pas d'entitlement).
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    /// Lit la clé existante ou en crée une au premier lancement. Silencieux.
    /// À invoquer depuis un contexte d'arrière-plan (les appels `SecItem*` bloquent).
    static func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try readKey() {
            return existing
        }
        return try createKey()
    }

    // MARK: - Lecture

    private static func readKey() throws -> SymmetricKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == keyByteCount else {
                throw Failure.keychain(errSecDecode)
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status)
        }
    }

    // MARK: - Création

    private static func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        var attributes = baseQuery
        attributes[kSecValueData as String] = keyData
        // La clé ne part ni dans une sauvegarde ni sur un autre Mac.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return key
    }
}
