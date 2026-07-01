//
//  CapturedContent.swift
//  ClipboardEnhanced
//
//  Contenu brut lu depuis le presse-papier, avant transformation en ClipboardItem.
//

import Foundation

/// Résultat d'une lecture du presse-papier par `PasteboardReader`.
///
/// Intermédiaire entre le pasteboard (AppKit) et le modèle persistant :
/// le `ClipboardStore` lui attribue un `id` et des dates pour créer un `ClipboardItem`.
struct CapturedContent {
    var type: ClipboardItemType

    /// Texte/URL : le contenu. Image : libellé (« 1920 × 1080 »). Fichier : nom du fichier.
    var text: String

    /// Données image normalisées en PNG (uniquement pour `.image`).
    var imageData: Data?

    /// Vignette PNG : image réduite (`.image`) ou icône système (`.file`).
    var thumbnailData: Data?

    /// Chemin du fichier (uniquement pour `.file`).
    var filePath: String?
}
