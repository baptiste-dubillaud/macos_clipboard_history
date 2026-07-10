//
//  ClipboardItemRow.swift
//  ClipboardEnhanced
//
//  Affichage d'un élément dans la liste.
//

import AppKit
import SwiftUI

struct ClipboardItemRow: View {
    let item: ClipboardItem
    /// L'élément vient d'être recopié : on affiche « Copié » avant la fermeture du panneau.
    let isRecentlyCopied: Bool
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    /// Gabarit de la zone d'actions : assez large pour « Copié » (le plus large des deux états).
    private static let trailingWidth: CGFloat = 62

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leadingVisual
                .frame(width: 32, height: 32)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                // Texte : 3 lignes max, troncature « … » au-delà.
                Text(item.text)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .font(.body)

                Text(item.lastCopiedAt.relativeDescription)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            // Largeur fixe : les actions apparaissent/disparaissent en opacité, jamais en
            // s'insérant dans la hiérarchie — sinon la colonne de texte se rétrécit au
            // survol et le texte se re-wrappe (2 lignes → 3).
            trailingArea
                .frame(width: Self.trailingWidth, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
        .onHover { isHovered = $0 }
    }

    /// Zone de droite : actions au survol, ou badge « Copié » — superposées, même gabarit.
    private var trailingArea: some View {
        ZStack(alignment: .trailing) {
            actions.opacity(isRecentlyCopied ? 0 : 1)
            if isRecentlyCopied {
                copiedBadge
            }
        }
    }

    /// L'épingle reste visible si l'item est épinglé ; la corbeille seulement au survol.
    private var actions: some View {
        HStack(spacing: 6) {
            Button(action: onTogglePin) {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(item.isPinned ? "Dépingler" : "Épingler")
            .opacity(isHovered || item.isPinned ? 1 : 0)
            .allowsHitTesting(isHovered || item.isPinned)

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Supprimer")
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .foregroundStyle(.secondary)
    }

    private var copiedBadge: some View {
        Label("Copié", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
            .lineLimit(1)
            .fixedSize()
    }

    private var rowBackground: Color {
        if isRecentlyCopied { return .green.opacity(0.12) }
        return isHovered ? Color.primary.opacity(0.06) : .clear
    }

    /// Vignette (image/fichier) si disponible, sinon le symbole du type.
    @ViewBuilder
    private var leadingVisual: some View {
        if let data = item.thumbnailData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: item.type.symbolName)
                .foregroundStyle(.secondary)
        }
    }
}
