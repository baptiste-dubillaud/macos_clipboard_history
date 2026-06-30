//
//  ClipboardItemType.swift
//  ClipboardEnhanced
//
//  Type de contenu d'un élément du presse-papier.
//

import Foundation

/// Catégorie d'un élément capturé.
///
/// Phase 1 : seuls `text` et `url` sont produits.
/// `image` et `file` arrivent en phase 5 (l'enum est défini dès maintenant
/// pour éviter une migration plus tard).
enum ClipboardItemType: String, Codable, CaseIterable {
    case text
    case url
    case image
    case file

    /// SF Symbol associé, utilisé dans l'UI.
    var symbolName: String {
        switch self {
        case .text:  return "text.alignleft"
        case .url:   return "link"
        case .image: return "photo"
        case .file:  return "doc"
        }
    }
}
