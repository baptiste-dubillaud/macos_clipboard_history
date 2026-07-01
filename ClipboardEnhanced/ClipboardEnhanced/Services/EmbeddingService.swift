//
//  EmbeddingService.swift
//  ClipboardEnhanced
//
//  Embeddings de texte sur-appareil (NLContextualEmbedding, framework Natural Language).
//  100 % local, gratuit, sans Apple Intelligence.
//

import NaturalLanguage

@MainActor
final class EmbeddingService {
    /// Modèle contextuel pour l'écriture latine (couvre fr/en).
    private let model: NLContextualEmbedding?

    /// `true` quand les assets sont chargés et le modèle utilisable.
    private(set) var isReady = false

    init() {
        model = NLContextualEmbedding(script: .latin)
    }

    /// Charge les assets (téléchargement possible au premier lancement) puis le modèle.
    /// Tant que ce n'est pas terminé, `vector(for:)` renvoie `nil` → recherche littérale.
    func prepare() async {
        guard let model else { return }

        if !model.hasAvailableAssets {
            await withCheckedContinuation { continuation in
                model.requestAssets { _, _ in
                    continuation.resume()
                }
            }
        }

        do {
            try model.load()
            isReady = true
        } catch {
            NSLog("[ClipboardEnhanced] Modèle d'embedding indisponible : \(error)")
            isReady = false
        }
    }

    /// Vecteur d'une chaîne (moyenne des vecteurs de tokens). `nil` si non prêt/vide.
    func vector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReady, let model, !trimmed.isEmpty,
              let result = try? model.embeddingResult(for: trimmed, language: nil) else {
            return nil
        }

        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) {
                sum[i] += vector[i]
            }
            count += 1
            return true
        }

        guard count > 0 else { return nil }
        let inverse = 1.0 / Double(count)
        return sum.map { Float($0 * inverse) }
    }
}
