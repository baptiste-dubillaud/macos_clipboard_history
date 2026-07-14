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
| Cible          | **macOS 26.5** (`MACOSX_DEPLOYMENT_TARGET`) | `MenuBarExtra` exige 13+, `SettingsLink` 14+ ; la cible réelle du projet est bien plus haute |
| Persistance    | **SQLite brut** (lib système `SQLite3`) | Zéro dépendance externe ; wrapper maison `Database`/`Statement` |
| Chiffrement    | **CryptoKit** (AES-GCM) + **Trousseau** | Contenus chiffrés au repos ; clé dans le Trousseau de session |
| Dédup          | **CryptoKit** (HMAC-SHA256 à clé)      | Empreinte déterministe mais non devinable |
| Sémantique     | **NLContextualEmbedding** (Natural Language) | Embeddings de texte sur-appareil |
| OCR            | **Vision**                             | Texte des images (cherchable) |
| Démarrage      | **SMAppService**                       | Lancement au login |
| Build          | Xcode + Swift Package Manager          | — |

Dépendances externes : **aucune** (SQLite, CryptoKit, NaturalLanguage, Vision,
Security, SMAppService sont système).

> Décision produit : **app minimale** — uniquement l'icône en barre de menus, **pas de raccourcis
> globaux** ni d'ouverture programmatique. (`MenuBarExtra` ne peut de toute façon pas être ouvert par API.)

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
- **Stockage par type** :
  - Texte / URL → string en base.
  - **Image → donnée binaire complète** (BLOB sur disque, pas une référence — une image copiée n'a pas de chemin).
  - **Fichier → chemin seul** (le fichier peut bouger/disparaître). Pas de bookmark : cf. phase 5.
- **Confidentialité** : les marqueurs `org.nspasteboard.ConcealedType` / `TransientType` existent, mais
  **on ne les respecte pas** (décision produit, cf. « Mode privé »). Tout est historisé.

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
| Fichier | **référence** : chemin + icône système (pas de copie des octets) | fichiers seulement ; **dossiers/répertoires ignorés** |

- **Image → octets stockés** car une capture/image web n'a pas de fichier source.
- **Fichier → référence stockée** (sémantique « copier un pointeur ») ; entrée obsolète si le fichier
  est déplacé/supprimé, ce qui est acceptable.
- **Pas de security-scoped bookmark ni d'entitlement** (décision phase 5) : recoller un fichier
  n'écrit que son URL, et c'est l'app réceptrice qui y accède avec ses propres droits. Un bookmark
  ne servirait qu'à *lire le contenu* du fichier depuis notre app — ce qu'on ne fait jamais.

### Interface
- Icône `clipboard` (SF Symbol) dans la barre de menus, toujours visible.
- Panneau `MenuBarExtra` style `.window` : barre de recherche en haut + liste scrollable.
- Rendu d'un item :
  - Texte/URL : **3 lignes max**, troncature `…` au-delà.
  - Image : thumbnail.
  - Fichier : icône système + nom.
  - Métadonnées : type, date relative, indicateur épinglé.
- Actions par item : **coller** (clic), **épingler/dépingler**, **supprimer**.
- Recherche temps réel, en mémoire (le texte d'un fichier est son nom ; celui d'une image, son OCR).

### Coller
- **Défaut (MVP) : « copier seulement »** — au clic, écrire l'item dans `NSPasteboard.general`
  et refermer le panneau. L'utilisateur colle lui-même (Cmd+V). Aucune permission requise.
- *Option future* : « copier + coller auto » via simulation `CGEvent` (demandera l'Accessibilité).

### Mode privé
- **Pas de filtrage automatique.** Les marqueurs `ConcealedType`/`TransientType` sont ignorés :
  un mot de passe copié depuis un gestionnaire **est** historisé.
  Raison : le filtre ne couvrait de toute façon que les gestionnaires natifs — une extension
  navigateur copie du texte brut sans marqueur, donc indétectable. Il donnait une **fausse
  impression de sécurité** pour une couverture partielle.
- **Le vrai rempart** : l'historique est 100 % local, et la base est **chiffrée au repos**
  (cf. « Sécurité »). Pas d'heuristique « ressemble à un mot de passe » — trop de faux positifs.
- **Contrôle manuel** : toggle « Pause » dans le panneau → suspend la capture.

### Recherche
- Hybride : correspondances littérales (sous-chaîne) **toujours en tête**, puis au plus 5 voisins
  sémantiques (`NLContextualEmbedding`, cosinus ≥ 0,50).
- Sémantique désactivée sous 3 caractères ; vecteur de requête recalculé après 250 ms
  d'inactivité, pour que l'ordre ne change pas à chaque frappe.
- Fallback littéral tant que le modèle sémantique n'est pas chargé.

### Réglages
- Fenêtre `Settings`, ouverte par le bouton engrenage du panneau (l'app `LSUIElement`
  n'a pas de menu applicatif). Purge immédiate au resserrement d'un réglage.
- Politique de rétention : durée (1–7 j) + nombre (10–200).
- Lancer au démarrage (`SMAppService.mainApp`) — état détenu par le système, pas par nous.

---

## Architecture

```
ClipboardEnhanced/ClipboardEnhanced/
├── ClipboardEnhancedApp.swift           # @main, MenuBarExtra, crée le store
├── Models/
│   ├── ClipboardItem.swift              # struct Identifiable (empreinte HMAC fournie par le store)
│   ├── ClipboardItemType.swift          # enum text/url/image/file (+ symbole SF)
│   ├── CapturedContent.swift            # contenu brut lu du pasteboard, avant persistance
│   └── AppSettings.swift                # ObservableObject, UserDefaults (rétention)
├── Store/
│   └── ClipboardStore.swift             # ObservableObject : source de vérité de l'UI,
│                                        #   ingestion, dédoublonnage, recherche, rétention
├── Services/
│   ├── ClipboardMonitor.swift           # Timer 0,5 s + changeCount
│   ├── PasteboardReader.swift           # lit le pasteboard, filtre les types sensibles
│   ├── PasteboardWriter.swift           # réécrit l'item (mode « copier seulement »)
│   ├── EmbeddingService.swift           # NLContextualEmbedding, prepare() async
│   └── DatabaseKeyStore.swift           # clé AES du Trousseau de session (sans biométrie)
├── Storage/
│   ├── Database.swift                   # wrapper SQLite3 maison (Database + Statement, WAL)
│   └── ClipboardRepository.swift        # schéma, migrations, CRUD, purge
├── UI/
│   ├── MenuPanelView.swift              # racine du panneau (recherche + liste + footer)
│   ├── ClipboardItemRow.swift           # rendu d'un élément
│   └── SettingsView.swift               # fenêtre Réglages (rétention, démarrage)
└── Utilities/
    ├── Date+Relative.swift
    ├── ImageProcessing.swift            # normalisation PNG + vignette ~300 px
    ├── ImageTextRecognizer.swift        # OCR Vision (asynchrone)
    ├── ContentCipher.swift              # AES-GCM (contenus) + HMAC (empreinte de dédoublonnage)
    └── VectorMath.swift                 # [Float] ⟷ BLOB, similarité cosinus
```

> Pas de `PrivacyFilter`, `RetentionService`, `DatabaseManager` ni `SearchBar` : il n'y a plus de
> filtrage sensible, la rétention et la recherche vivent dans `ClipboardStore`, l'init de la base
> dans `ClipboardRepository`, et la barre de recherche est une sous-vue de `MenuPanelView`.

### Flux
1. `ClipboardMonitor` détecte un changement de `changeCount` → notifie `ClipboardStore`.
2. `ClipboardStore` ignore la capture si la pause manuelle est active ;
   sinon `PasteboardReader` renvoie un `CapturedContent` typé (aucun filtrage de confidentialité).
3. `ClipboardStore` dédoublonne par empreinte HMAC (remonte l'existant) ou insère,
   puis persiste via `ClipboardRepository`, qui chiffre les contenus (AES-GCM) avant écriture.
   Au démarrage, `prepareStorage()` charge la clé du Trousseau et déchiffre l'historique.
4. `ClipboardStore.applyRetention()` purge après chaque ajout (nombre) et via timer 120 s (âge).
5. `MenuPanelView` observe le store et affiche `visibleItems` (tri + recherche hybride).
6. Clic → `PasteboardWriter` écrit dans `NSPasteboard.general` ; la capture suivante est ignorée.

---

## Performance
- Polling 0,5 s, lecture seulement si `changeCount` a changé.
- Vignettes générées à l'insertion ; la donnée image pleine (`data`) est **exclue du `SELECT`
  de liste** et chargée à la demande au moment de recoller (mémoire légère).
- Index SQLite : unique sur `content_hash` (dédoublonnage), simple sur `last_copied_at`.
- **Pas de FTS5** : l'historique est plafonné à 200 éléments, le filtrage en mémoire
  (`ClipboardStore.visibleItems`) est instantané. Cf. PLAN.md phase 3.

## Sécurité & confidentialité
- 100 % local, aucun réseau, aucune télémétrie.
- Les types *concealed*/*transient* sont **ignorés** : mots de passe inclus dans l'historique.
- **Chiffrement au repos (AES-GCM)** : les colonnes de contenu (`text`, `data`, `thumbnail`,
  `file_path`, `embedding`) sont chiffrées. Un `sqlite3 history.sqlite` ne montre que du binaire.
  - Clé AES-256 dans le **Trousseau de session** (`DatabaseKeyStore`), créée et relue en silence.
    Ce trousseau **ne requiert aucun entitlement** → pas de profil de provisioning à renouveler.
  - `content_hash` est un **HMAC-SHA256 à clé** (pas un SHA-256 nu) : déterministe pour le
    dédoublonnage, mais non devinable — sinon l'empreinte d'un mot de passe court serait
    cassable par force brute alors même que le contenu est chiffré.
  - **Pas de verrou biométrique** (décision produit) : protéger contre « quelqu'un devant la
    session déverrouillée » aurait imposé le Trousseau data-protection (Touch ID) + son
    entitlement + un profil expirant tous les 7 jours (compte Apple gratuit). Jugé disproportionné
    pour un presse-papier local. Perdre la clé du Trousseau = historique illisible (assumé).
  - Mode dégradé : si le Trousseau refuse la clé, clé éphémère en mémoire, rien n'est persisté.
- **L'app est sandboxée** (`ENABLE_APP_SANDBOX = YES`) et n'utilise ni `CGEvent` ni bookmarks.
  Signée avec la Personal Team (compte gratuit) ; la distribution reste ouverte (phase 9).

---

## Roadmap (voir PLAN.md pour le détail par étapes)
1. Setup projet + barre de menus vide.
2. Monitoring + stockage texte.
3. UI liste + recherche.
4. Coller (pasteboard + Cmd+V).
5. Images, fichiers, URLs.
6. Épinglage, suppression, rétention.
7. Mode privé (pause + respect concealed).
8. Réglages + lancement au démarrage.
9. Polish, tests, distribution.

## Conventions de code
- Services = classes `final`, injectées, testables (pas de singletons globaux quand évitable).
- UI = SwiftUI, état via `@Observable` / `ObservableObject`.
- Pas de logique métier dans les vues.
- Commits par phase fonctionnelle.
