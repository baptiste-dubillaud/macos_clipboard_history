//
//  ClipboardEnhancedApp.swift
//  ClipboardEnhanced
//
//  Point d'entrée : app menu bar (sans icône Dock, cf. LSUIElement).
//

import SwiftUI

@main
struct ClipboardEnhancedApp: App {
    @StateObject private var store = ClipboardStore()

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(store: store)
        } label: {
            Image(systemName: store.isCapturePaused ? "clipboard.fill" : "clipboard")
        }
        .menuBarExtraStyle(.window)

        // L'app est LSUIElement : elle n'a pas de menu applicatif, donc cette fenêtre
        // n'est atteignable que par le bouton « Réglages » du panneau.
        Settings {
            SettingsView(settings: store.settings)
        }
    }
}
