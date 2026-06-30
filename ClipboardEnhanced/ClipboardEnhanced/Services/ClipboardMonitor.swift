//
//  ClipboardMonitor.swift
//  ClipboardEnhanced
//
//  Surveille le presse-papier système.
//

import AppKit

/// Observe `NSPasteboard.general` et notifie l'arrivée de nouveau contenu.
///
/// macOS n'expose aucune notification de changement du presse-papier :
/// on interroge donc périodiquement `changeCount` (technique standard).
/// La lecture du presse-papier ne nécessite aucune permission.
///
/// Le contenu copié depuis un autre appareil Apple (Universal Clipboard)
/// atterrit dans `NSPasteboard.general` et est capturé comme une copie locale.
@MainActor
final class ClipboardMonitor {

    /// Appelé quand du texte (ou une URL sous forme de texte) vient d'être copié.
    var onNewText: ((String) -> Void)?

    private let pasteboard: NSPasteboard
    private let pollInterval: TimeInterval
    private var lastChangeCount: Int
    private var timer: Timer?

    init(pasteboard: NSPasteboard = .general, pollInterval: TimeInterval = 0.5) {
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        // On part du compteur courant pour ne pas ré-ingérer ce qui est
        // déjà dans le presse-papier au lancement.
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            // Timer délivre sur le run loop principal ; on est déjà @MainActor.
            MainActor.assumeIsolated { self?.checkForChanges() }
        }
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkForChanges() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Phase 1 : on ne traite que le texte.
        if let string = pasteboard.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onNewText?(string)
        }
    }
}
