//
//  ClipboardStore.swift
//  ClipboardEnhanced
//
//  Source de vérité de l'historique. La mémoire (`items`) sert de cache pour
//  l'UI ; le dépôt SQLite est le miroir durable.
//

import AppKit
import Combine

/// Détient l'historique et orchestre la capture.
///
/// Le store génère les `id` et décide du dédoublonnage : la mémoire et la base
/// restent ainsi cohérentes (même `id` des deux côtés). Si le dépôt ne peut pas
/// s'ouvrir, l'app continue en mémoire seule (mode dégradé, non persistant).
@MainActor
final class ClipboardStore: ObservableObject {

    @Published private(set) var items: [ClipboardItem] = []
    @Published var searchQuery: String = "" {
        didSet { recomputeQueryVector() }
    }

    /// Mode privé manuel : quand `true`, rien n'est capturé (les copies faites
    /// pendant la pause ne sont pas historisées). Non persisté : reprise au lancement.
    @Published var isCapturePaused = false

    let settings: AppSettings

    private let monitor: ClipboardMonitor
    private let repository: ClipboardRepository?
    private let reader: PasteboardReader
    private let writer: PasteboardWriter
    private let embeddingService: EmbeddingService

    /// Vecteur de la requête courante (recalculé quand `searchQuery` change).
    private var queryVector: [Float]?

    /// Seuil de similarité cosinus pour retenir un résultat sémantique.
    private static let semanticThreshold: Float = 0.30
    /// Nombre max de résultats sémantiques ajoutés aux correspondances littérales.
    private static let maxSemanticResults = 25

    /// Évite de ré-ingérer notre propre écriture lorsqu'on recopie un élément.
    private var suppressNextCapture = false

    /// Vérifie périodiquement la rétention par âge (pendant que l'app est inactive).
    private var retentionTimer: Timer?
    private static let retentionInterval: TimeInterval = 120

    /// Taille maximale d'un contenu texte (cf. limites de stockage). Au-delà : ignoré.
    private static let maxTextBytes = 1_000_000

    init(
        monitor: ClipboardMonitor? = nil,
        repository: ClipboardRepository? = nil,
        reader: PasteboardReader? = nil,
        writer: PasteboardWriter? = nil,
        settings: AppSettings? = nil,
        embeddingService: EmbeddingService? = nil
    ) {
        self.monitor = monitor ?? ClipboardMonitor()
        self.reader = reader ?? PasteboardReader()
        self.writer = writer ?? PasteboardWriter()
        self.settings = settings ?? AppSettings()
        self.embeddingService = embeddingService ?? EmbeddingService()

        if let repository {
            self.repository = repository
        } else {
            do {
                self.repository = try ClipboardRepository()
            } catch {
                NSLog("[ClipboardEnhanced] Dépôt indisponible, mode mémoire seule : \(error)")
                self.repository = nil
            }
        }

        // Charge l'historique persisté, puis applique la rétention au lancement.
        items = (try? self.repository?.fetchAll()) ?? []
        applyRetention()

        self.monitor.onChange = { [weak self] in
            self?.captureCurrent()
        }
        // Le store est créé au lancement (backing du MenuBarExtra) : on démarre
        // la surveillance ici pour capturer dès le départ, panneau ouvert ou non.
        self.monitor.start()

        retentionTimer = Timer.scheduledTimer(withTimeInterval: Self.retentionInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        }

        // Charge le modèle d'embedding (asynchrone), puis calcule les vecteurs manquants.
        Task { [weak self] in
            await self?.embeddingService.prepare()
            self?.backfillEmbeddings()
        }
    }

    // MARK: - Lecture

    /// Historique trié (épinglés d'abord, puis du plus récent au plus ancien),
    /// filtré par la recherche.
    ///
    /// Recherche **hybride** : d'abord les correspondances littérales (sous-chaîne),
    /// puis, si le modèle est prêt, les résultats sémantiques les plus proches
    /// (similarité cosinus au-dessus du seuil), triés par pertinence.
    var visibleItems: [ClipboardItem] {
        let sorted = items.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }

        let literal = sorted.filter { $0.text.localizedCaseInsensitiveContains(query) }

        guard embeddingService.isReady, let queryVector else { return literal }

        let literalIDs = Set(literal.map(\.id))
        let semantic = items
            .filter { !literalIDs.contains($0.id) }
            .compactMap { item -> (item: ClipboardItem, score: Float)? in
                guard let embedding = item.embedding else { return nil }
                let score = VectorMath.cosineSimilarity(queryVector, embedding)
                return score >= Self.semanticThreshold ? (item, score) : nil
            }
            .sorted { $0.score > $1.score }
            .prefix(Self.maxSemanticResults)
            .map(\.item)

        return literal + semantic
    }

    // MARK: - Capture

    private func captureCurrent() {
        if suppressNextCapture {
            suppressNextCapture = false
            return
        }
        // Mode privé : on ignore le contenu copié pendant la pause.
        guard !isCapturePaused else { return }
        guard let captured = reader.read() else { return }

        // Limite de taille pour le texte (les images sont déjà bornées par le reader).
        if captured.type == .text || captured.type == .url {
            guard captured.text.utf8.count <= Self.maxTextBytes else { return }
        }

        let hash = ClipboardItem.contentHash(captured)

        // Dédoublonnage côté store : un contenu identique remonte au lieu d'être dupliqué.
        if let index = items.firstIndex(where: { $0.contentHash == hash }) {
            let now = Date()
            items[index].lastCopiedAt = now
            persist { try $0.touch(id: items[index].id, date: now) }
            return
        }

        let item = ClipboardItem(captured: captured)
        items.insert(item, at: 0)
        persist { try $0.insert(item) }

        // Applique immédiatement la limite de nombre après un nouvel ajout.
        applyRetention()

        // Calcule le vecteur sémantique du nouvel élément (si le modèle est prêt).
        computeEmbedding(id: item.id, force: false)

        // OCR asynchrone : remplace le libellé de repli si du texte est détecté.
        if captured.type == .image, let png = captured.imageData {
            recognizeImageText(itemID: item.id, pngData: png)
        }
    }

    /// Lance l'OCR hors du thread principal, puis met à jour l'élément si du texte est trouvé.
    private func recognizeImageText(itemID: UUID, pngData: Data) {
        Task.detached(priority: .utility) { [weak self] in
            let text = ImageTextRecognizer.recognizeText(in: pngData)
            guard !text.isEmpty else { return }
            await MainActor.run {
                self?.updateItemText(id: itemID, text: text)
            }
        }
    }

    private func updateItemText(id: UUID, text: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].text = text
        }
        persist { try $0.updateText(id: id, text: text) }
        // Le texte a changé (OCR) : recalcule le vecteur sémantique.
        computeEmbedding(id: id, force: true)
    }

    // MARK: - Embeddings

    /// Calcule et stocke le vecteur d'un élément. `force` recalcule même si un
    /// vecteur existe déjà (ex. après OCR). No-op si le modèle n'est pas prêt.
    private func computeEmbedding(id: UUID, force: Bool) {
        guard embeddingService.isReady,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        if !force, items[index].embedding != nil { return }

        guard let vector = embeddingService.vector(for: items[index].text) else { return }
        items[index].embedding = vector
        persist { try $0.updateEmbedding(id: id, vector: vector) }
    }

    /// Calcule les vecteurs manquants (au chargement du modèle).
    private func backfillEmbeddings() {
        guard embeddingService.isReady else { return }
        for item in items where item.embedding == nil {
            computeEmbedding(id: item.id, force: false)
        }
        recomputeQueryVector()
    }

    private func recomputeQueryVector() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        queryVector = query.isEmpty ? nil : embeddingService.vector(for: query)
    }

    // MARK: - Actions

    /// Replace l'élément dans le presse-papier système (mode « copier seulement »).
    func copyToPasteboard(_ item: ClipboardItem) {
        suppressNextCapture = true
        writer.write(item, imageData: fullImageData(for: item))

        let now = Date()
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].lastCopiedAt = now
        }
        persist { try $0.touch(id: item.id, date: now) }
    }

    /// Donnée image pleine : en mémoire si présente, sinon chargée depuis la base.
    private func fullImageData(for item: ClipboardItem) -> Data? {
        if let data = item.imageData { return data }
        guard item.type == .image, let repository else { return nil }
        return try? repository.imageData(id: item.id)
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        let pinned = items[index].isPinned
        persist { try $0.setPinned(id: item.id, pinned: pinned) }
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        persist { try $0.delete(id: item.id) }
    }

    // MARK: - Helpers

    /// Purge la base selon la politique de rétention puis recharge la mémoire.
    /// Les éléments épinglés sont préservés. Sans dépôt (mode dégradé), no-op.
    private func applyRetention() {
        guard let repository else { return }
        let cutoff = Date().addingTimeInterval(-Double(settings.retentionDays) * 86_400)
        do {
            try repository.purge(olderThan: cutoff, keepingNewest: settings.maxItems)
            items = try repository.fetchAll()
        } catch {
            NSLog("[ClipboardEnhanced] Rétention échouée : \(error)")
        }
    }

    /// Applique une opération de persistance si le dépôt est disponible.
    private func persist(_ operation: (ClipboardRepository) throws -> Void) {
        guard let repository else { return }
        do {
            try operation(repository)
        } catch {
            NSLog("[ClipboardEnhanced] Écriture base échouée : \(error)")
        }
    }
}
