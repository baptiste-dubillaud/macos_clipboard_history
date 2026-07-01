# Clipboard History — macOS Menu Bar App

App macOS native (SwiftUI) qui ajoute une icône de presse-papier dans la barre de menus.
Au clic, elle affiche l'historique copier/coller (texte, URL, image, fichier) avec recherche,
épinglage, suppression et raccourcis clavier.

---

## Stack technique

| Domaine        | Choix                                  | Raison |
|----------------|----------------------------------------|--------|
| Langage        | Swift 5.9+                             | Natif, performant |
| UI             | SwiftUI + `MenuBarExtra` (`.window`)  | Vue riche dans la barre de menus (macOS 13+) |
| Cible          | macOS 13 Ventura minimum               | `MenuBarExtra` requiert 13+ |
| Persistance    | **SQLite brut** (lib système `SQLite3`) | Zéro dépendance externe ; wrapper maison `Database`/`Statement` |
| Hash/dédup     | **CryptoKit** (SHA-256)                | Framework système, empreinte de contenu |
| Raccourcis     | **KeyboardShortcuts** (S. Sorhus)      | Hotkeys globaux configurables (phase 7) |
| Build          | Xcode + Swift Package Manager          | — |

Dépendances externes : **aucune pour le cœur** (SQLite + CryptoKit sont système).
`KeyboardShortcuts` sera ajouté en phase 7 pour les raccourcis globaux.

---

## Réalités techniques macOS (à garder en tête)

- **Pas d'API de notification de changement du pasteboard.** On *poll* `NSPasteboard.general.changeCount`
  via un `Timer` (~0,5 s). C'est ce que font tous les gestionnaires (Maccy, Paste…).
- **Universal Clipboard** : ce qui est copié sur un autre appareil Apple (même compte iCloud,
  Handoff actif) atterrit dans `NSPasteboard.general` → capturé automatiquement comme une copie locale.
- **Permissions** :
  - Lire le pasteboard → **aucune permission**.
  - Écrire dans le pasteboard (mode « copier seulement », notre défaut) → **aucune permission**.
  - Coller dans l'app active (simuler Cmd+V via `CGEvent`) → **Accessibilité** *(option future, pas dans le MVP)*.
  - Raccourcis clavier globaux → **Accessibilité / Input Monitoring**.
- **Stockage par type** :
  - Texte / URL → string en base.
  - **Image → donnée binaire complète** (BLOB sur disque, pas une référence — une image copiée n'a pas de chemin).
  - **Fichier → security-scoped bookmark** + chemin (le fichier peut bouger/disparaître).
- **Confidentialité native** : respecter `org.nspasteboard.ConcealedType` et `org.nspasteboard.TransientType`.
  Un item marqué *concealed* (mots de passe) **n'est jamais historisé**. C'est le cœur du mode private.

---

## Spécifications

### Historique
- Types : texte, URL, image, fichier (**dossiers exclus**).
- Rétention **configurable** :
  - par durée : 1 à 7 jours,
  - par nombre : jusqu'à 200 éléments.
- Le plus restrictif des deux s'applique. Nettoyage automatique périodique.
- Persiste après redémarrage (SQLite dans `Application Support`).
- Dédoublonnage : recopier un contenu identique remonte l'item existant (met à jour `lastCopiedAt`).

#### Limites de stockage par type
| Type | Stockage | Limite |
|------|----------|--------|
| Texte / URL | contenu en base | ≤ ~1 Mo/élément, au-delà ignoré |
| Image | **données complètes** (BLOB) + thumbnail (~300 px) | PNG/JPEG/TIFF, ≤ ~10 Mo, au-delà ignoré |
| Fichier | **référence** : chemin + security-scoped bookmark (pas de copie des octets) | fichiers seulement ; **dossiers/répertoires ignorés** |

- **Image → octets stockés** car une capture/image web n'a pas de fichier source.
- **Fichier → référence stockée** (sémantique « copier un pointeur ») ; entrée obsolète si le fichier
  est déplacé/supprimé, ce qui est acceptable.
- Sandbox : réinjecter un fichier après redémarrage nécessitera l'entitlement
  `com.apple.security.files.bookmarks.app-scope` (traité en phase 5).

### Interface
- Icône `clipboard` (SF Symbol) dans la barre de menus, toujours visible.
- Panneau `MenuBarExtra` style `.window` : barre de recherche en haut + liste scrollable.
- Rendu d'un item :
  - Texte/URL : **3 lignes max**, troncature `…` au-delà.
  - Image : thumbnail.
  - Fichier : icône système + nom.
  - Métadonnées : type, date relative, indicateur épinglé.
- Actions par item : **coller** (clic), **épingler/dépingler**, **supprimer**.
- Recherche temps réel (FTS sur le texte ; nom de fichier pour les fichiers).

### Coller
- **Défaut (MVP) : « copier seulement »** — au clic, écrire l'item dans `NSPasteboard.general`
  et refermer le panneau. L'utilisateur colle lui-même (Cmd+V). Aucune permission requise.
- *Option future* : « copier + coller auto » via simulation `CGEvent` (demandera l'Accessibilité).

### Raccourcis (configurables)
- Ouvrir le panneau (défaut : Cmd+Shift+V).
- Naviguer ↑/↓ + Entrée pour coller, Échap pour fermer.

### Mode private
- Auto : items `ConcealedType`/`TransientType` jamais stockés.
- Manuel : toggle « Pause » dans le menu → suspend la capture (pour saisies sensibles).

### Réglages
- Politique de rétention (durée + nombre).
- Lancer au démarrage (`SMAppService`).
- Coller automatiquement vs copier seulement.
- Raccourci global.

---

## Architecture

```
ClipboardHistory/
├── App/
│   └── ClipboardHistoryApp.swift        # @main, MenuBarExtra, injection des services
├── Models/
│   ├── ClipboardItem.swift              # struct + Codable + GRDB record
│   ├── ClipboardItemType.swift          # enum text/url/image/file
│   └── AppSettings.swift                # ObservableObject, UserDefaults
├── Services/
│   ├── ClipboardMonitor.swift           # Timer + changeCount, lit le pasteboard
│   ├── PasteboardWriter.swift           # écrit l'item + simule Cmd+V (CGEvent)
│   ├── RetentionService.swift           # purge selon durée/nombre
│   └── PrivacyFilter.swift              # détecte concealed/transient + pause manuelle
├── Storage/
│   ├── DatabaseManager.swift            # init GRDB, migrations, FTS
│   └── ClipboardRepository.swift        # CRUD + recherche + dédoublonnage
├── UI/
│   ├── MenuPanelView.swift              # racine du panneau
│   ├── SearchBar.swift
│   ├── ClipboardItemRow.swift
│   └── SettingsView.swift
└── Utilities/
    └── Date+Relative.swift
```

### Flux
1. `ClipboardMonitor` détecte un changement → lit `NSPasteboard.general`.
2. `PrivacyFilter` rejette concealed/transient ou si en pause.
3. `ClipboardRepository` insère/dédoublonne dans SQLite.
4. `RetentionService` purge périodiquement.
5. `MenuPanelView` observe le repo et affiche la liste filtrée par la recherche.
6. Clic → `PasteboardWriter` écrit + (option) colle.

---

## Performance
- Polling 0,5 s, lecture seulement si `changeCount` a changé.
- Thumbnails d'images générés à l'insertion, stockés à part du BLOB plein.
- Index SQLite sur `lastCopiedAt`, `isPinned` ; table FTS5 pour la recherche texte.
- Images/fichiers volumineux : BLOBs hors de la table principale ou fichiers dans `Application Support`.

## Sécurité & confidentialité
- 100 % local, aucun réseau, aucune télémétrie.
- Respect des types concealed/transient (cf. ci-dessus).
- Chiffrage de la base : hors MVP (à évaluer plus tard, ex. SQLCipher).
- Sandbox App Store : possible mais complique CGEvent/bookmarks → décision à la phase distribution.

---

## Roadmap (voir PLAN.md pour le détail par étapes)
1. Setup projet + barre de menus vide.
2. Monitoring + stockage texte.
3. UI liste + recherche.
4. Coller (pasteboard + Cmd+V).
5. Images, fichiers, URLs.
6. Épinglage, suppression, rétention.
7. Mode private + raccourcis globaux.
8. Réglages + lancement au démarrage.
9. Polish, tests, distribution.

## Conventions de code
- Services = classes `final`, injectées, testables (pas de singletons globaux quand évitable).
- UI = SwiftUI, état via `@Observable` / `ObservableObject`.
- Pas de logique métier dans les vues.
- Commits par phase fonctionnelle.
