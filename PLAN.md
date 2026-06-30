# Plan d'implémentation — Clipboard History

Plan itératif. Chaque phase est **livrable et testable** avant de passer à la suivante.
À la fin de chaque phase : l'app compile, se lance, et la fonctionnalité de la phase marche.

---

## Phase 0 — Setup du projet ✅
**But :** une app menu bar vide qui se lance.

- [x] Projet Xcode « macOS App », SwiftUI (nommé `ClipboardEnhanced`).
- [x] `INFOPLIST_KEY_LSUIElement = YES` (build settings, Debug + Release) — pas d'icône Dock.
- [~] Dépendances SPM `GRDB.swift` / `KeyboardShortcuts` → reportées en phase 2/7 (inutiles avant).
- [x] `MenuBarExtra` (SF Symbol `clipboard`), style `.window`.
- [x] Panneau avec état vide.
- [x] Build vérifié via `xcodebuild` → **BUILD SUCCEEDED**.

**Validation :** l'icône apparaît dans la barre de menus, le clic ouvre le panneau.

> Note : le projet est **sandboxé** (`ENABLE_APP_SANDBOX = YES`) et isolé `@MainActor` par défaut.

---

## Phase 1 — Capture du texte ✅
**But :** copier du texte → il apparaît en mémoire.

- [x] `ClipboardItemType` (enum, 4 cas prêts) et `ClipboardItem` (modèle).
- [x] `ClipboardMonitor` : `Timer` 0,5 s, compare `NSPasteboard.general.changeCount`.
- [x] `ClipboardStore` (ObservableObject) : ingestion + dédoublonnage + détection URL.
- [x] `MenuPanelView` + `ClipboardItemRow` : liste triée (épinglés d'abord), texte 3 lignes + `…`.
- [x] **Bonus déjà en place** : recherche temps réel, copier (mode « copier seulement »),
      épingler, supprimer — tout en mémoire.

**Validation :** copier plusieurs textes → ils s'empilent, plus récent en haut ;
cliquer recopie ; la recherche filtre.

> La persistance (SQLite/GRDB) arrive en phase 2 : pour l'instant l'historique est en mémoire
> (perdu au redémarrage).

---

## Phase 2 — Persistance SQLite (GRDB)
**But :** l'historique survit au redémarrage.

- [ ] `DatabaseManager` : ouverture DB dans `Application Support/ClipboardHistory/`, migrations.
- [ ] Schéma : table `clipboard_item` (id, type, content, preview, createdAt, lastCopiedAt, isPinned).
- [ ] `ClipboardRepository` : insert, fetchAll (tri épinglés puis date), delete.
- [ ] **Dédoublonnage** : si contenu identique existe → update `lastCopiedAt` au lieu d'insérer.
- [ ] Brancher `ClipboardMonitor` → `ClipboardRepository`.
- [ ] Le panneau lit la base (observation réactive via GRDB `ValueObservation`).

**Validation :** copier, quitter, relancer → l'historique est toujours là.

---

## Phase 3 — UI propre + recherche
**But :** panneau utilisable au quotidien.

- [ ] `ClipboardItemRow` : texte 3 lignes max + `…`, date relative, badge type.
- [ ] `SearchBar` en haut du panneau.
- [ ] Table FTS5 sur le contenu texte ; `ClipboardRepository.search(query)`.
- [ ] Filtrage temps réel.
- [ ] Liste scrollable, largeur/hauteur fixes raisonnables, état vide.

**Validation :** taper dans la recherche filtre instantanément.

---

## Phase 4 — Coller (mode « copier seulement »)
**But :** cliquer un item le remet dans le presse-papier (l'utilisateur colle avec Cmd+V).

- [ ] `PasteboardWriter.write(item)` : écrit l'item dans `NSPasteboard.general`.
- [ ] Fermer le panneau au clic, feedback visuel (« copié »).
- [ ] **Pas** de simulation Cmd+V ni de permission Accessibilité dans le MVP.
- [ ] *(Option future, non bloquante)* : réglage « copier + coller auto » via `CGEvent`.

**Validation :** cliquer un item ancien → Cmd+V dans n'importe quelle app recolle ce contenu.

---

## Phase 5 — Types riches : URL, image, fichier
**But :** supporter tout le contenu, pas seulement le texte. **Dossiers exclus.**

- [ ] Détection du type depuis les `NSPasteboard.PasteboardType` disponibles.
- [ ] **URL** : reconnue, affichage dédié (favicon optionnel plus tard).
- [ ] **Image** : stocker la donnée complète (BLOB ≤ ~10 Mo, sinon ignoré) + thumbnail ~300 px.
- [ ] **Fichier** : security-scoped bookmark + chemin + icône système.
      **Ignorer les répertoires** (vérifier `isDirectory`).
- [ ] Entitlement `com.apple.security.files.bookmarks.app-scope` (réinjection après redémarrage).
- [ ] Limite texte : ignorer les contenus > ~1 Mo.
- [ ] Rendu adapté par type dans `ClipboardItemRow`.
- [ ] `PasteboardWriter` sait réécrire chaque type correctement.

**Validation :** copier une image / un fichier / une URL → rendu correct + recollage correct ;
copier un dossier → non historisé ; image énorme → ignorée.

---

## Phase 6 — Épinglage, suppression, rétention
**But :** gérer le contenu dans le temps.

- [ ] Épingler/dépingler (les épinglés ignorent la purge et restent en haut).
- [ ] Supprimer un item (bouton au survol).
- [ ] `RetentionService` : purge périodique selon durée (1–7 j) ET nombre (≤200).
- [ ] Suppression des BLOBs/fichiers orphelins associés.

**Validation :** dépasser la limite → les vieux non-épinglés disparaissent ; les épinglés restent.

---

## Phase 7 — Mode private + raccourcis globaux
**But :** confidentialité et accès clavier.

- [ ] `PrivacyFilter` : ignorer `org.nspasteboard.ConcealedType` / `TransientType`.
- [ ] Toggle « Pause la capture » dans le menu (mode private manuel).
- [ ] `KeyboardShortcuts` : hotkey global pour ouvrir le panneau (défaut Cmd+Shift+V).
- [ ] Navigation clavier dans la liste (↑/↓, Entrée = coller, Échap = fermer).

**Validation :** copier depuis un gestionnaire de mots de passe → rien n'est historisé ;
le raccourci ouvre le panneau partout.

---

## Phase 8 — Réglages + démarrage
**But :** configuration utilisateur.

- [ ] `AppSettings` (UserDefaults) : rétention, auto-paste, raccourci, lancer au démarrage.
- [ ] `SettingsView` (fenêtre Réglages standard).
- [ ] Lancer au démarrage via `SMAppService`.

**Validation :** régler 3 jours / 50 items → la rétention s'applique ; relance au login OK.

---

## Phase 9 — Polish, tests, distribution
**But :** qualité finale.

- [ ] Tests unitaires : repository (CRUD, dédoublonnage, recherche), rétention, privacy filter.
- [ ] Gestion d'erreurs (DB inaccessible, permission refusée).
- [ ] Icônes, libellés, accessibilité VoiceOver.
- [ ] Signature + notarisation (distribution directe) **ou** sandbox App Store (décision ici).
- [ ] README utilisateur.

**Validation :** build release signé qui s'installe et tourne sur une machine propre.

---

## Décisions actées
- **Collage : « copier seulement »** pour le MVP (pas de Cmd+V auto, pas de permission Accessibilité).
  Le collage automatique reste une option future non bloquante.

## Décisions reportées (à trancher en temps voulu)
- **Distribution : à décider en phase 9** (directe .dmg vs App Store sandbox). On code sans présumer :
  éviter les API incompatibles sandbox tant que possible, trancher au moment de la distribution.
- Chiffrage de la base (SQLCipher) — sécurité renforcée.
- Favicons / aperçus riches d'URL.
- Sync iCloud propre à l'app (explicitement hors scope actuel).
