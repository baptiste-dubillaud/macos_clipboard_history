//
//  AppSettings.swift
//  ClipboardEnhanced
//
//  Préférences utilisateur (rétention dans UserDefaults ; le lancement au
//  démarrage est détenu par le système via SMAppService).
//

import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    /// Bornes autorisées (cf. cahier des charges).
    static let maxAllowedDays = 7
    static let maxAllowedItems = 200

    /// Lancement au démarrage. **Délibérément absent de `UserDefaults`** : la source de
    /// vérité est le système — l'utilisateur peut désactiver l'app depuis Réglages Système
    /// sans passer par nous. On reflète donc `SMAppService.mainApp.status`.
    @Published private(set) var launchAtLogin: Bool = false

    /// Dernière erreur d'(dés)enregistrement, affichée dans les réglages.
    /// Attendue non-nil pour un build non signé lancé depuis Xcode.
    @Published private(set) var launchAtLoginError: String?

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

        refreshLaunchAtLogin()
    }

    // MARK: - Lancement au démarrage

    /// Relit l'état système. À appeler à l'ouverture des réglages : l'utilisateur a pu
    /// changer l'état ailleurs depuis le dernier affichage.
    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Enregistre/désenregistre l'app comme élément de démarrage.
    /// En cas d'échec, l'état affiché est resynchronisé sur le système : la case ne
    /// reste jamais cochée si l'enregistrement n'a pas pris.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    private enum Keys {
        static let retentionDays = "retentionDays"
        static let maxItems = "maxItems"
    }
}
