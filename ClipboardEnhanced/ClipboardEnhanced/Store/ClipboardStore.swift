//
//  ClipboardStore.swift
//  ClipboardEnhanced
//
//  Source de vérité de l'historique (en mémoire en phase 1).
//

import AppKit
import Combine

/// Détient l'historique et orchestre la capture.
///
/// Phase 1 : stockage en mémoire. En phase 2, `items` sera alimenté par
/// le dépôt SQLite (GRDB) via observation réactive ; l'API publique
/// (ingest / copy / pin / delete) restera identique.
@MainActor
final class ClipboardStore: ObservableObject {

    @Published private(set) var items: [ClipboardItem] = []
    @Published var searchQuery: String = ""

    private let monitor: ClipboardMonitor

    /// Évite de ré-ingérer notre propre écriture lorsqu'on recopie un élément.
    private var suppressNextCapture = false

    init(monitor: ClipboardMonitor? = nil) {
        self.monitor = monitor ?? ClipboardMonitor()
        self.monitor.onNewText = { [weak self] text in
            self?.ingestText(text)
        }
        // Le store est créé au lancement (backing du MenuBarExtra) : on démarre
        // la surveillance ici pour capturer dès le départ, panneau ouvert ou non.
        self.monitor.start()
    }

    // MARK: - Lecture

    /// Historique trié (épinglés d'abord, puis du plus récent au plus ancien),
    /// filtré par la recherche courante.
    var visibleItems: [ClipboardItem] {
        let sorted = items.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Capture

    private func ingestText(_ text: String) {
        if suppressNextCapture {
            suppressNextCapture = false
            return
        }

        // Dédoublonnage : un contenu identique remonte au lieu d'être dupliqué.
        if let index = items.firstIndex(where: { $0.text == text }) {
            items[index].lastCopiedAt = Date()
            return
        }

        let type: ClipboardItemType = Self.looksLikeURL(text) ? .url : .text
        items.insert(ClipboardItem(type: type, text: text), at: 0)
    }

    // MARK: - Actions

    /// Replace l'élément dans le presse-papier système (mode « copier seulement »).
    func copyToPasteboard(_ item: ClipboardItem) {
        suppressNextCapture = true
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)

        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].lastCopiedAt = Date()
        }
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
    }

    // MARK: - Helpers

    /// Détection légère d'URL (suffisante pour la phase 1).
    private static func looksLikeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), trimmed.count <= 2048 else { return false }
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }
}
