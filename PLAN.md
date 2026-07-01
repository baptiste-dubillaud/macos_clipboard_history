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

## Phase 2 — Persistance SQLite (brut, sans dépendance) ✅
**But :** l'historique survit au redémarrage.

- [x] `Database` / `Statement` : wrapper maison sur `SQLite3` système (WAL, `user_version`).
- [x] Schéma `clipboard_item` complet **dès maintenant** (colonnes image/fichier incluses
      → pas de migration en phase 5) + index unique `content_hash` + index `last_copied_at`.
- [x] `ClipboardRepository` : insert / fetchAll (épinglés puis date) / touch / setPinned / delete.
- [x] **Dédoublonnage** décidé côté store (mémoire ↔ base cohérentes via `id` partagé) ;
      empreinte SHA-256 (CryptoKit) en garde-fou côté base.
- [x] Limite texte ~1 Mo appliquée à l'ingestion.
- [x] Mode dégradé mémoire seule si la base ne s'ouvre pas (l'app ne crashe jamais).
- [x] Build vérifié → **BUILD SUCCEEDED**.

**Validation :** copier, quitter, relancer → l'historique est toujours là.
Base dans `~/Library/Containers/com.bde.ClipboardEnhanced/Data/Library/Application Support/ClipboardEnhanced/history.sqlite` (sandbox).

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

## Phase 5 — Types riches : URL, image, fichier ✅
**But :** supporter tout le contenu, pas seulement le texte. **Dossiers exclus.**

- [x] `PasteboardReader` : détection par UTI, priorité fichier → image → URL → texte.
- [x] **URL** : reconnue (http/https), type dédié.
- [x] **Image** : PNG normalisé (BLOB ≤ 10 Mo, sinon ignoré) + vignette ~300 px ;
      **chargement paresseux** de la donnée pleine (mémoire légère).
- [x] **Fichier** : chemin + nom + icône système comme vignette ; **dossiers ignorés** (`isDirectory`).
- [x] `PasteboardWriter` : réécrit image (NSImage) / fichier (fileURL) / texte selon le type.
- [x] `ClipboardItemRow` : vignette image/icône fichier, sinon symbole du type.
- [x] Limite texte ~1 Mo (déjà en place).
- [x] Garde confidentialité minimal : contenus *concealed*/*transient* non capturés (mode privé complet → phase 7).
- [x] **Libellé image intelligent** : OCR local (Vision, asynchrone) → sinon `alt` HTML → sinon
      nom/domaine de l'URL source → sinon « Image · L × H ». Rend les captures d'écran cherchables.
- [x] Build vérifié → **BUILD SUCCEEDED**.

**Décision** : pas de security-scoped bookmark ni d'entitlement. Re-coller un fichier n'écrit que
son URL ; c'est l'app réceptrice qui accède au fichier avec ses droits. Les bookmarks ne seraient
utiles que pour *lire le contenu* du fichier (inutile ici).

**Validation :** copier image / fichier / URL → rendu + recollage corrects ;
copier un dossier → non historisé ; image > 10 Mo → ignorée ; copie depuis gestionnaire de mots de passe → ignorée.

---

## Phase 6 — Épinglage, suppression, rétention ✅
**But :** gérer le contenu dans le temps.

- [x] Épingler/dépingler (déjà en place ; les épinglés ignorent la purge et restent en haut).
- [x] Supprimer un item (bouton au survol, déjà en place).
- [x] `AppSettings` (UserDefaults) : `retentionDays` (1–7), `maxItems` (≤200).
- [x] `ClipboardRepository.purge(olderThan:keepingNewest:)` : par âge ET par nombre, épinglés exemptés.
- [x] Application : au lancement, après chaque ajout (limite de nombre), et via timer 120 s (âge).
- [x] Pas de fichiers orphelins : images = BLOB dans la même ligne, fichiers = références → un `DELETE` suffit.
- [x] Build vérifié → **BUILD SUCCEEDED**.

**Validation :** dépasser 200 → les vieux non-épinglés disparaissent ; les épinglés restent.
(UI de réglage des valeurs : phase 8 ; pour l'instant défauts 7 j / 200.)

---

## Phase 6bis — Recherche sémantique (hybride, on-device) ✅
**But :** retrouver un élément par le sens, pas seulement par sous-chaîne. 100 % local, gratuit.

- [x] `EmbeddingService` autour de **`NLContextualEmbedding`** (script latin, fr/en) :
      `prepare()` async (chargement des assets), `vector(for:)` = moyenne des vecteurs de tokens.
- [x] `VectorMath` : sérialisation BLOB ⟷ `[Float]` + similarité cosinus.
- [x] Migration schéma v2 : colonne `embedding` (BLOB).
- [x] Vecteur calculé à l'insertion (tous types) + **recalcul après OCR** ; backfill au chargement du modèle.
- [x] Recherche **hybride** : littérales d'abord, puis sémantiques (cosinus ≥ 0.30, top 25),
      force brute sur ≤ 200 éléments. Requête vectorisée en cache (recalcul à chaque frappe).
- [x] Fallback littéral tant que le modèle n'est pas prêt (dégradation propre, un seul espace vectoriel).
- [x] Build vérifié → **BUILD SUCCEEDED**.

**Limite assumée** : sémantique sur le **texte** uniquement (y compris texte OCR des images).
Pas d'API Apple texte→image (pas de CLIP).

**Validation :** copier « rendez-vous demain 14h » puis chercher « réunion » → l'élément remonte.
(NB : au 1ᵉʳ lancement, le modèle peut mettre quelques secondes à se charger → recherche littérale en attendant.)

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
