//
//  ClipboardStore.swift
//  ClipboardEnhanced
//
//  Source de vérité de l'historique. La mémoire (`items`) sert de cache pour
//  l'UI ; le dépôt SQLite est le miroir durable.
//

import AppKit
import Combine
import CryptoKit

/// Détient l'historique et orchestre la capture.
///
/// Le store génère les `id` et décide du dédoublonnage : la mémoire et la base
/// restent ainsi cohérentes (même `id` des deux côtés). Si le dépôt ne peut pas
/// s'ouvrir, l'app continue en mémoire seule (mode dégradé, non persistant).
@MainActor
final class ClipboardStore: ObservableObject {

    @Published private(set) var items: [ClipboardItem] = []
    @Published var searchQuery: String = "" {
        didSet { scheduleQueryVectorRecompute() }
    }

    /// Mode privé manuel : quand `true`, rien n'est capturé (les copies faites
    /// pendant la pause ne sont pas historisées). Non persisté : reprise au lancement.
    @Published var isCapturePaused = false

    /// Élément qui vient d'être recopié : la ligne affiche « Copié » le temps que
    /// le panneau se referme. Remis à `nil` à la réouverture du panneau.
    @Published private(set) var recentlyCopiedID: UUID?

    let settings: AppSettings

    private let monitor: ClipboardMonitor
    private let reader: PasteboardReader
    private let writer: PasteboardWriter
    private let embeddingService: EmbeddingService

    /// Dépôt et chiffreur, disponibles une fois la clé chargée (au démarrage).
    /// Le chiffreur est toujours présent après `prepareStorage()` — clé du Trousseau,
    /// ou clé éphémère de session si le Trousseau refuse (mode dégradé mémoire seule) ;
    /// le dépôt reste `nil` dans ce dernier cas, donc rien n'est persisté.
    private var repository: ClipboardRepository?
    private var cipher: ContentCipher?

    /// Copies survenues pendant le bref chargement de la clé (démarrage). Elles sont
    /// mises de côté puis rejouées : sans ce tampon, une app lancée au démarrage
    /// perdrait les premières copies avant que la clé ne soit prête.
    private var pendingCaptures: [CapturedContent] = []
    private var pendingBytes = 0

    /// Plafond mémoire du tampon : une image fait jusqu'à 10 Mo.
    private static let maxPendingBytes = 64 * 1024 * 1024

    /// Vecteur de la requête courante. `@Published` : sa mise à jour différée (debounce)
    /// doit rafraîchir la liste, alors que `searchQuery` a déjà cessé de changer.
    @Published private var queryVector: [Float]?

    /// Recalcul différé du vecteur de requête (annulé à chaque frappe).
    private var queryVectorTask: Task<Void, Never>?

    /// Seuil de similarité cosinus pour retenir un résultat sémantique.
    /// Volontairement strict : en dessous, des éléments sans rapport remontent.
    private static let semanticThreshold: Float = 0.50
    /// Nombre max de résultats sémantiques ajoutés aux correspondances littérales.
    private static let maxSemanticResults = 5
    /// En deçà, une requête est trop courte pour porter du sens : littéral seulement.
    private static let minSemanticQueryLength = 3
    /// Délai d'inactivité avant de recalculer le vecteur : évite que l'ordre des
    /// résultats sémantiques change à chaque caractère tapé.
    private static let queryDebounce: Duration = .milliseconds(250)

    /// Évite de ré-ingérer notre propre écriture lorsqu'on recopie un élément.
    private var suppressNextCapture = false

    /// Vérifie périodiquement la rétention par âge (pendant que l'app est inactive).
    private var retentionTimer: Timer?

    /// Abonnements aux réglages (rétention).
    private var cancellables = Set<AnyCancellable>()
    private static let retentionInterval: TimeInterval = 120

    /// Taille maximale d'un contenu texte (cf. limites de stockage). Au-delà : ignoré.
    private static let maxTextBytes = 1_000_000

    init(
        monitor: ClipboardMonitor? = nil,
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

        self.monitor.onChange = { [weak self] in
            self?.captureCurrent()
        }
        // Le store est créé au lancement (backing du MenuBarExtra) : on démarre
        // la surveillance ici pour capturer dès le départ, panneau ouvert ou non.
        self.monitor.start()

        // Charge la clé, ouvre la base chiffrée et rejoue les copies tamponnées.
        Task { [weak self] in await self?.prepareStorage() }

        retentionTimer = Timer.scheduledTimer(withTimeInterval: Self.retentionInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        }

        // Purge immédiate quand l'utilisateur resserre la rétention dans les réglages.
        // `@Published` émet dans `willSet` : on diffère d'un tour de boucle, sinon
        // `applyRetention()` relirait encore l'ancienne valeur.
        // (`dropFirst()` sur chacun : à l'abonnement, `@Published` rejoue la valeur courante.)
        self.settings.$retentionDays.dropFirst()
            .merge(with: self.settings.$maxItems.dropFirst())
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyRetention() }
            }
            .store(in: &cancellables)

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
    /// puis, si le modèle est prêt, au plus `maxSemanticResults` voisins sémantiques
    /// au-dessus de `semanticThreshold`, triés par pertinence.
    ///
    /// Le bloc littéral est toujours en tête et se met à jour à chaque frappe ; le bloc
    /// sémantique dépend de `queryVector`, recalculé en différé (cf. `scheduleQueryVectorRecompute`).
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

    // MARK: - Stockage

    /// Charge la clé, ouvre la base chiffrée et charge l'historique déchiffré.
    ///
    /// Si le Trousseau refuse la clé, on bascule en **mode dégradé** : une clé
    /// éphémère de session chiffre les contenus en mémoire (le chiffreur reste
    /// disponible pour l'empreinte de dédoublonnage), mais rien n'est persisté.
    /// L'app fonctionne, l'historique est simplement perdu au redémarrage.
    private func prepareStorage() async {
        do {
            // Les appels Trousseau peuvent bloquer : hors du MainActor.
            let key = try await Task.detached(priority: .userInitiated) {
                try DatabaseKeyStore.loadOrCreateKey()
            }.value

            let cipher = ContentCipher(key: key)
            self.cipher = cipher

            let repository = try ClipboardRepository(cipher: cipher)
            self.repository = repository
            items = try repository.fetchAll()
            applyRetention()
        } catch {
            // Trousseau refusé ou base illisible : clé éphémère, rien n'est persisté.
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            NSLog("[ClipboardEnhanced] Stockage indisponible, mode mémoire seule : \(message)")
            if cipher == nil { cipher = ContentCipher(key: SymmetricKey(size: .bits256)) }
            repository = nil
        }

        replayPendingCaptures()
        backfillEmbeddings()
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

        // Avant que la clé ne soit prête (bref, au démarrage) : on tamponne.
        guard cipher != nil else {
            buffer(captured)
            return
        }
        ingest(captured)
    }

    /// Met de côté une copie survenue avant que la clé ne soit prête.
    private func buffer(_ captured: CapturedContent) {
        let size = (captured.imageData?.count ?? 0) + captured.text.utf8.count
        guard pendingBytes + size <= Self.maxPendingBytes else { return }
        pendingCaptures.append(captured)
        pendingBytes += size
    }

    /// Rejoue les copies tamponnées, dans l'ordre, une fois la clé disponible.
    private func replayPendingCaptures() {
        let captures = pendingCaptures
        pendingCaptures = []
        pendingBytes = 0
        for captured in captures {
            ingest(captured)
        }
    }

    /// Insère (ou dédoublonne) un contenu capturé. Exige la clé de session.
    private func ingest(_ captured: CapturedContent) {
        guard let cipher else { return }
        let hash = cipher.fingerprint(captured)

        // Dédoublonnage côté store : un contenu identique remonte au lieu d'être dupliqué.
        if let index = items.firstIndex(where: { $0.contentHash == hash }) {
            let now = Date()
            items[index].lastCopiedAt = now
            persist { try $0.touch(id: items[index].id, date: now) }
            return
        }

        let item = ClipboardItem(captured: captured, contentHash: hash)
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
            // `updateItemText` est isolé au MainActor : l'`await` y hop automatiquement.
            await self?.updateItemText(id: itemID, text: text)
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

    /// Programme le recalcul du vecteur après une courte inactivité.
    ///
    /// Pendant la frappe on **conserve** le vecteur précédent : les correspondances
    /// littérales se resserrent à chaque caractère (instantané), tandis que le bloc
    /// sémantique reste stable et ne se réordonne qu'une fois, à la fin de la saisie.
    private func scheduleQueryVectorRecompute() {
        queryVectorTask?.cancel()

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minSemanticQueryLength else {
            queryVector = nil
            return
        }

        queryVectorTask = Task { [weak self] in
            try? await Task.sleep(for: Self.queryDebounce)
            guard !Task.isCancelled else { return }
            self?.recomputeQueryVector()
        }
    }

    private func recomputeQueryVector() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minSemanticQueryLength else {
            queryVector = nil
            return
        }
        queryVector = embeddingService.vector(for: query)
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
        recentlyCopiedID = item.id
    }

    /// À appeler à la réouverture du panneau : efface le retour visuel « Copié ».
    func clearCopyFeedback() {
        recentlyCopiedID = nil
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
