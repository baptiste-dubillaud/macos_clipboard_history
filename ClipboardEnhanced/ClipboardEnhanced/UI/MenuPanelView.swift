//
//  MenuPanelView.swift
//  ClipboardEnhanced
//
//  Panneau affiché depuis la barre de menus.
//

import SwiftUI

struct MenuPanelView: View {
    @ObservedObject var store: ClipboardStore

    /// Délai laissant voir le badge « Copié » avant que le panneau ne se referme.
    private static let copyFeedbackDuration: Duration = .milliseconds(400)

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if store.isCapturePaused {
                pausedBanner
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(width: 340, height: 440)
        .onAppear { store.clearCopyFeedback() }
    }

    // MARK: - Actions

    /// Recopie l'élément, montre brièvement « Copié », puis referme le panneau.
    private func copy(_ item: ClipboardItem) {
        withAnimation(.easeOut(duration: 0.12)) {
            store.copyToPasteboard(item)
        }
        Task {
            try? await Task.sleep(for: Self.copyFeedbackDuration)
            dismissPanel()
        }
    }

    /// `@Environment(\.dismiss)` est sans effet sur le panneau d'un `MenuBarExtra`
    /// en style `.window` : il faut fermer le `NSPanel` sous-jacent.
    private func dismissPanel() {
        NSApp.keyWindow?.close()
    }

    private var pausedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
            Text("Capture en pause — rien n'est enregistré")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Sous-vues

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Rechercher…", text: $store.searchQuery)
                .textFieldStyle(.plain)
            if !store.searchQuery.isEmpty {
                Button {
                    store.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        let items = store.visibleItems
        if items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        ClipboardItemRow(
                            item: item,
                            isRecentlyCopied: store.recentlyCopiedID == item.id,
                            onCopy: { copy(item) },
                            onTogglePin: { store.togglePin(item) },
                            onDelete: { store.delete(item) }
                        )
                    }
                }
                .padding(6)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: store.searchQuery.isEmpty ? "clipboard" : "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(store.searchQuery.isEmpty ? "Aucun élément copié" : "Aucun résultat")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(store.items.count) élément\(store.items.count > 1 ? "s" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                store.isCapturePaused.toggle()
            } label: {
                Label(
                    store.isCapturePaused ? "Reprendre" : "Pause",
                    systemImage: store.isCapturePaused ? "play.fill" : "pause.fill"
                )
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help(store.isCapturePaused ? "Reprendre la capture" : "Suspendre la capture (mode privé)")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Réglages")
            // L'app est accessoire (LSUIElement) : sans activation explicite, la fenêtre
            // de réglages s'ouvre derrière celle de l'app au premier plan.
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
            })

            Button("Quitter") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
