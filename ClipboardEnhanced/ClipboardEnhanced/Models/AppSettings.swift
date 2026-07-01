//
//  AppSettings.swift
//  ClipboardEnhanced
//
//  Préférences utilisateur (persistées dans UserDefaults).
//  L'UI de réglages arrive en phase 8 ; le modèle existe dès la phase 6
//  car la rétention en dépend.
//

import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    /// Bornes autorisées (cf. cahier des charges).
    static let maxAllowedDays = 7
    static let maxAllowedItems = 200

    /// Durée de rétention en jours (1…7).
    @Published var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: Keys.retentionDays) }
    }

    /// Nombre max d'éléments non épinglés (1…200).
    @Published var maxItems: Int {
        didSet { UserDefaults.standard.set(maxItems, forKey: Keys.maxItems) }
    }

    init() {
        let defaults = UserDefaults.standard
        let storedDays = defaults.object(forKey: Keys.retentionDays) as? Int ?? Self.maxAllowedDays
        let storedItems = defaults.object(forKey: Keys.maxItems) as? Int ?? Self.maxAllowedItems
        // Affecter des propriétés stockées dans `init` ne déclenche pas `didSet`.
        retentionDays = min(max(storedDays, 1), Self.maxAllowedDays)
        maxItems = min(max(storedItems, 1), Self.maxAllowedItems)
    }

    private enum Keys {
        static let retentionDays = "retentionDays"
        static let maxItems = "maxItems"
    }
}
