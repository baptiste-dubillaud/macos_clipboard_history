//
//  ClipboardItem.swift
//  ClipboardEnhanced
//
//  Modèle d'un élément de l'historique du presse-papier.
//

import Foundation

/// Un élément capturé depuis le presse-papier.
///
/// `text` porte : le contenu (texte/URL), un libellé de dimensions (image),
/// ou le nom du fichier (fichier). Les données lourdes (`imageData`) sont
/// chargées à la demande : un item issu de la base a `imageData == nil`
/// jusqu'à ce qu'on en ait besoin (cf. `ClipboardRepository.imageData(id:)`).
struct ClipboardItem: Identifiable {
    let id: UUID
    var type: ClipboardItemType
    var text: String
    var createdAt: Date
    var lastCopiedAt: Date
    var isPinned: Bool

    /// Données image complètes (PNG). `nil` si non-image ou non encore chargé.
    var imageData: Data?

    /// Vignette PNG (image réduite ou icône fichier) — légère, toujours chargée.
    var thumbnailData: Data?

    /// Chemin du fichier (type `.file`).
    var filePath: String?

    /// Vecteur sémantique du texte (recherche sémantique). `nil` si non calculé.
    var embedding: [Float]?

    /// Empreinte stable du contenu, pour le dédoublonnage.
    let contentHash: String

    init(
        id: UUID = UUID(),
        type: ClipboardItemType,
        text: String,
        createdAt: Date = Date(),
        lastCopiedAt: Date = Date(),
        isPinned: Bool = false,
        imageData: Data? = nil,
        thumbnailData: Data? = nil,
        filePath: String? = nil,
        embedding: [Float]? = nil,
        contentHash: String
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.isPinned = isPinned
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.filePath = filePath
        self.embedding = embedding
        self.contentHash = contentHash
    }

    /// Construit un item à partir d'un contenu fraîchement capturé.
    ///
    /// L'empreinte est fournie par l'appelant : elle est calculée par `ContentCipher`
    /// (HMAC à clé), le modèle n'a pas accès à la clé de session.
    init(captured: CapturedContent, contentHash: String, id: UUID = UUID(), date: Date = Date()) {
        self.init(
            id: id,
            type: captured.type,
            text: captured.text,
            createdAt: date,
            lastCopiedAt: date,
            isPinned: false,
            imageData: captured.imageData,
            thumbnailData: captured.thumbnailData,
            filePath: captured.filePath,
            contentHash: contentHash
        )
    }
}
