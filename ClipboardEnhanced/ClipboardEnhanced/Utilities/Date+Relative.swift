//
//  Date+Relative.swift
//  ClipboardEnhanced
//
//  Formatage relatif des dates pour l'UI.
//

import Foundation

extension Date {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// En deçà, on affiche un libellé fixe : le compte des secondes défile sous les yeux
    /// et n'apporte rien. Couvre aussi les dates légèrement dans le futur (dérive
    /// d'horloge), que le formateur rendrait par « dans 0 s ».
    private static let justNowThreshold: TimeInterval = 60

    /// Ex. « À l'instant », « il y a 2 min ».
    var relativeDescription: String {
        let elapsed = Date().timeIntervalSince(self)
        guard elapsed >= Self.justNowThreshold else { return "À l'instant" }
        return Self.relativeFormatter.localizedString(for: self, relativeTo: Date())
    }
}
