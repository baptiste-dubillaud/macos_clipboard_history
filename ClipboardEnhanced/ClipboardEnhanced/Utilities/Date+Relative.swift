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

    /// Ex. « il y a 2 min ».
    var relativeDescription: String {
        Self.relativeFormatter.localizedString(for: self, relativeTo: Date())
    }
}
