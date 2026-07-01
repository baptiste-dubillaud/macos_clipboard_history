//
//  PasteboardWriter.swift
//  ClipboardEnhanced
//
//  Réécrit un élément dans le presse-papier système (mode « copier seulement »).
//

import AppKit

@MainActor
struct PasteboardWriter {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Place l'élément dans le presse-papier. `imageData` est la donnée pleine
    /// (chargée à la demande) requise pour les images.
    func write(_ item: ClipboardItem, imageData: Data?) {
        pasteboard.clearContents()

        switch item.type {
        case .image:
            if let imageData, let image = NSImage(data: imageData) {
                pasteboard.writeObjects([image])
            }

        case .file:
            // On écrit l'URL : l'app réceptrice (Finder…) accède au fichier avec ses droits.
            if let path = item.filePath {
                pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
            }

        case .text, .url:
            pasteboard.setString(item.text, forType: .string)
        }
    }
}
