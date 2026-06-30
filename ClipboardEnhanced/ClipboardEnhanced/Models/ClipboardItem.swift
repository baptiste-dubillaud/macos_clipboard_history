//
//  ClipboardItem.swift
//  ClipboardEnhanced
//
//  Modèle d'un élément de l'historique du presse-papier.
//

import Foundation

/// Un élément capturé depuis le presse-papier.
///
/// Phase 1 : modèle en mémoire pour texte/URL.
/// En phase 2 il sera adossé à un enregistrement GRDB (SQLite) ;
/// les champs `createdAt` / `lastCopiedAt` / `isPinned` sont déjà là
/// pour le tri, le dédoublonnage et la rétention à venir.
struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    var type: ClipboardItemType

    /// Contenu texte (pour `text`/`url`) ou libellé d'affichage.
    var text: String

    /// Première fois que ce contenu a été vu.
    var createdAt: Date

    /// Dernière fois que ce contenu a été copié (sert au tri et au dédoublonnage).
    var lastCopiedAt: Date

    var isPinned: Bool

    init(
        id: UUID = UUID(),
        type: ClipboardItemType,
        text: String,
        createdAt: Date = Date(),
        lastCopiedAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.isPinned = isPinned
    }
}
