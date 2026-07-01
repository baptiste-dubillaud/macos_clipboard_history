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
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

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

            // Actions visibles au survol (l'épingle reste si l'item est épinglé).
            HStack(spacing: 6) {
                if isHovered || item.isPinned {
                    Button(action: onTogglePin) {
                        Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(item.isPinned ? "Dépingler" : "Épingler")
                }
                if isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Supprimer")
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
        .onHover { isHovered = $0 }
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
