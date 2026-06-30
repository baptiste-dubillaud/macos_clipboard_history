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
        MenuBarExtra("Clipboard History", systemImage: "clipboard") {
            MenuPanelView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
