//
//  PasteboardReader.swift
//  ClipboardEnhanced
//
//  Lit le presse-papier système et en extrait un CapturedContent typé.
//

import AppKit
import UniformTypeIdentifiers

/// Transforme l'état courant de `NSPasteboard` en `CapturedContent`.
///
/// Ordre de priorité : fichier (hors dossier) → image → URL → texte.
/// Respecte les marqueurs de confidentialité (mots de passe) : un contenu
/// *concealed*/*transient* n'est pas capturé (garde minimal ; mode privé complet en phase 7).
@MainActor
struct PasteboardReader {
    private let pasteboard: NSPasteboard

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func read() -> CapturedContent? {
        let types = pasteboard.types ?? []

        // Confidentialité : ne jamais historiser un contenu marqué sensible.
        if types.contains(Self.concealedType) || types.contains(Self.transientType) {
            return nil
        }

        if let file = readFile() { return file }
        if let image = readImage(types: types) { return image }
        return readText()
    }

    // MARK: - Fichier (dossiers exclus)

    private func readFile() -> CapturedContent? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              let url = urls.first else {
            return nil
        }
        // Exclure les répertoires.
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard !isDirectory else { return nil }

        return CapturedContent(
            type: .file,
            text: url.lastPathComponent,
            imageData: nil,
            thumbnailData: ImageProcessing.fileIconPNG(forPath: url.path),
            filePath: url.path
        )
    }

    // MARK: - Image (capture, image web… sans fichier source)

    private func readImage(types: [NSPasteboard.PasteboardType]) -> CapturedContent? {
        let hasImageType = types.contains { type in
            UTType(type.rawValue)?.conforms(to: .image) ?? false
        }
        guard hasImageType,
              let image = NSImage(pasteboard: pasteboard),
              let png = ImageProcessing.normalizedPNG(from: image),
              png.count <= ImageProcessing.maxImageBytes else {
            return nil
        }

        return CapturedContent(
            type: .image,
            // Libellé de repli immédiat ; l'OCR (asynchrone) le remplacera s'il trouve du texte.
            text: imageFallbackLabel(for: image),
            imageData: png,
            thumbnailData: ImageProcessing.thumbnailPNG(from: image),
            filePath: nil
        )
    }

    /// Meilleur libellé synchrone disponible : alt HTML → source URL → dimensions.
    private func imageFallbackLabel(for image: NSImage) -> String {
        if let alt = htmlAltText() { return alt }
        if let source = imageSourceLabel() { return source }
        return "Image · \(ImageProcessing.dimensionLabel(from: image))"
    }

    /// Attribut `alt` d'une image copiée depuis une page web (représentation HTML).
    private func htmlAltText() -> String? {
        guard let html = pasteboard.string(forType: .html),
              let regex = try? NSRegularExpression(
                pattern: "alt=[\"']([^\"']+)[\"']", options: [.caseInsensitive]
              ) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let alt = String(html[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
        return alt.isEmpty ? nil : alt
    }

    /// Nom de fichier de l'URL source (`chat.jpg`) ou domaine (`wikipedia.org`).
    private func imageSourceLabel() -> String? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL],
              let url = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) else {
            return nil
        }
        let name = url.lastPathComponent
        if name.contains("."), name.count > 1 { return name }
        return url.host
    }

    // MARK: - Texte / URL

    private func readText() -> CapturedContent? {
        guard let string = pasteboard.string(forType: .string) else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let type: ClipboardItemType = Self.looksLikeURL(trimmed) ? .url : .text
        return CapturedContent(type: type, text: string, imageData: nil, thumbnailData: nil, filePath: nil)
    }

    private static func looksLikeURL(_ text: String) -> Bool {
        guard !text.contains(" "), text.count <= 2048 else { return false }
        return text.hasPrefix("http://") || text.hasPrefix("https://")
    }
}
