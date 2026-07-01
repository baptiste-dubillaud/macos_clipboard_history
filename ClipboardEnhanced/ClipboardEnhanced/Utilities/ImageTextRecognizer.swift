//
//  ImageTextRecognizer.swift
//  ClipboardEnhanced
//
//  OCR local (framework Vision) pour libeller et rendre cherchables les images.
//

import ImageIO
import Vision

enum ImageTextRecognizer {
    /// Longueur max du texte extrait conservé (label + recherche).
    private static let maxLength = 500

    /// Extrait le texte d'une image PNG. Fonction pure, appelable hors du thread
    /// principal (l'OCR peut prendre 100–300 ms). Retourne "" si aucun texte.
    nonisolated static func recognizeText(in pngData: Data) -> String {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return ""
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["fr-FR", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.count > maxLength ? String(joined.prefix(maxLength)) : joined
    }
}
