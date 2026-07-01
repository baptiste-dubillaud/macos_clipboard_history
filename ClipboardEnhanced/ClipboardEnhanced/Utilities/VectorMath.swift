//
//  VectorMath.swift
//  ClipboardEnhanced
//
//  Sérialisation de vecteurs (BLOB) et similarité cosinus.
//

import Foundation

enum VectorMath {
    /// Encode un vecteur de `Float` en `Data` (stockage BLOB).
    static func data(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Décode un `Data` en vecteur de `Float` (copie, sans problème d'alignement).
    static func vector(from data: Data) -> [Float] {
        var result = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.stride)
        guard !result.isEmpty else { return [] }
        _ = result.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return result
    }

    /// Similarité cosinus ∈ [-1, 1]. Retourne 0 si dimensions incompatibles.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}
