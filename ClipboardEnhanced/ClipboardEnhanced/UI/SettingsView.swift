//
//  SettingsView.swift
//  ClipboardEnhanced
//
//  Fenêtre Réglages standard (scène `Settings`).
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Rétention") {
                Stepper(value: $settings.retentionDays, in: 1...AppSettings.maxAllowedDays) {
                    LabeledContent("Conserver pendant") {
                        Text("\(settings.retentionDays) jour\(settings.retentionDays > 1 ? "s" : "")")
                    }
                }

                Stepper(value: $settings.maxItems, in: 10...AppSettings.maxAllowedItems, step: 10) {
                    LabeledContent("Nombre maximum") {
                        Text("\(settings.maxItems) éléments")
                    }
                }

                Text("La règle la plus restrictive s'applique. Les éléments épinglés ne sont jamais purgés.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Démarrage") {
                Toggle("Lancer au démarrage de la session", isOn: launchAtLoginBinding)

                if let error = settings.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { settings.refreshLaunchAtLogin() }
    }

    /// L'écriture passe par le système ; la lecture reflète l'état réel, pas l'intention.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { settings.setLaunchAtLogin($0) }
        )
    }
}
