# Ember — Cahier des charges

*Document de référence produit. Moteur open-source : ANEForge. Application grand public : Ember.*
*Version 0.1 — 2026-06-12.*

---

## 1. Vision

> **Transformer le Mac de n'importe qui en une IA personnelle qui apprend de ses propres données, vit entièrement en local, et finit par agir sur tout l'ordinateur — d'une simplicité enfantine, dans la philosophie Apple.**

Ember n'est pas « encore un chatbot local ». C'est **une présence** : une IA qui vous connaît, que vous contrôlez, qui ne vous trahit jamais (rien ne quitte la machine), et dont l'**expérience visuelle est aussi forte que la technologie**.

Ambition : devenir *le* nom de l'IA personnelle locale sur Mac — au point d'être stratégique pour Apple.

---

## 2. Principes directeurs (non négociables)

1. **100% local.** Aucune donnée ne quitte la machine. Pas de cloud, pas de compte obligatoire, pas de traçage.
2. **Le visuel vaut la fonctionnalité.** Chaque écran doit être au niveau d'une page produit Apple. Une fonctionnalité sans une forme superbe est considérée incomplète.
3. **Simplicité « mamie ».** Zéro jargon visible. Tout ce qui est technique est caché ou traduit en langage humain.
4. **Honnêteté.** On n'affiche jamais une capacité qu'on n'a pas (ex : « Neural Engine activé », pas « entraîné sur l'ANE » tant que non prouvé).
5. **L'utilisateur garde la main.** Tout ce que l'IA sait est inspectable, modifiable, supprimable.
6. **Open-core.** Le moteur (ANEForge) est open source ; l'app et l'expérience sont le produit.

---

## 3. L'élément signature : l'orbe-braise interactive

L'**orbe** (la braise) est à la fois le **logo**, le **bouton** et l'**âme visuelle** d'Ember. Exigence centrale : elle doit **réagir en temps réel à l'état de l'IA.**

| État | Comportement visuel attendu |
|------|------------------------------|
| **Repos** | braise qui respire lentement, lueur douce ambre |
| **Écoute** (voix/saisie) | pulsation plus vive, halo qui suit le rythme |
| **Réflexion / travail** | **rougeoiement intense, cœur incandescent qui palpite** — on doit *sentir* que ça calcule |
| **Parle / répond** | ondulations synchronisées à la sortie (token par token) |
| **Apprentissage** | flamme plus haute/chaude + progression visible |
| **Erreur** | brève pulsation d'alerte, puis retour au calme |

L'orbe est **cliquable** (bouton principal : parler / interrompre) et présente partout : Dock, fenêtre, barre latérale, accueil. **C'est le cœur battant du produit.**

---

## 4. Périmètre fonctionnel

### 4.A — Cœur : l'IA personnelle  *(état : fait, à raffiner)*
- Créer une IA, lui apprendre ses données (glisser-déposer), discuter — en 3 gestes.
- Apprentissage incrémental (versions v1, v2…).
- 100% local, sur Apple Silicon, Neural Engine activé pour l'inférence.

### 4.B — CRUD & gestion des IA  *(état : fait)*
- Créer / lister / **supprimer** une IA (avec confirmation, irréversible).
- Renommer (à ajouter), dupliquer (P2).

### 4.C — Paramétrage  *(état : base faite, à étendre)*
- **Choix du modèle** de base (léger / équilibré / puissant).
- **Persona** : « comment l'IA doit se comporter » (ton, langue, style).
- **Longueur des réponses**, température (P1).
- **Réglages d'agent & d'orchestration** (P2, lié au mode Her) : comment les agents doivent agir, dans quel ordre, avec quelles permissions.

### 4.D — Mémoire personnelle  *(état : éditable + sémantique faite, à fiabiliser)*
- Faits stockés dans une mémoire **inspectable / éditable / supprimable** (`memory / remember / forget`).
- **Rappel fiable** : mots-clés + sémantique multilingue (« métier » trouve « boulanger »).
- À venir : timeline des faits, sources, catégories, recherche.

### 4.E — Mode « Her » : plein-ordinateur  *(étoile polaire, chantier majeur dédié)*
La grande ambition. À construire comme une phase à part entière, jamais bâclée.
- **Voix** : entrée (STT local) + sortie (TTS local) — conversation mains-libres.
- **Agent** : l'IA agit sur l'ordinateur (fichiers, apps, recherche, automatisations) sur **plusieurs tâches**.
- **Orchestration** : plusieurs agents/spécialistes coordonnés, paramétrables par l'utilisateur.
- **Permissions** : contrôle explicite, granulaire, révocable (sécurité maximale — agir sur l'ordi est sensible).
- **Toujours en local**, basse consommation grâce à l'ANE (apprentissage/inférence en arrière-plan possible).

### 4.F — Qualité des modèles  *(en cours)*
- Modèles **Instruct** + format de chat correct (fait).
- Montée en gamme : **SmolLM2-1.7B-Instruct** (libre) puis **Llama-3.2-1B** (token requis).
- **Accélération ANE** réelle pour rendre les gros modèles fluides en local (le vrai intérêt de l'ANE).

---

## 5. Périmètre visuel  *(au même rang que le fonctionnel)*

1. **Identité Ember cohérente** entre le site et l'app : thème sombre chaud, braise, typographie éditoriale.
2. **Orbe interactive** (cf. §3) — l'exigence visuelle n°1.
3. **App au niveau page produit Apple** : pas un « dossier ». Profondeur, lueurs, micro-animations, transitions fluides, vide maîtrisé.
4. **Chat vivant** : bulles soignées, réponse token-par-token, l'orbe qui réagit pendant la génération.
5. **Onboarding magique** : le premier lancement doit donner le « waouh » (créer son IA = un moment).
6. **Cohérence multi-tailles** : fenêtre redimensionnable, lisible, sans débordement.
7. **Icône = la braise** (fait), Dock + fenêtre.

---

## 6. Technique & architecture

- **Moteur** : Rust (`ane-core` : forward/backward, LoRA, BLAS) + ObjC (`ane-sys` : accès ANE) + Python (orchestration, HF) + Swift (app).
- **Inférence ANE** : via Core ML public (computeUnits=All). Preuve de dispatch op-par-op = Core ML Performance Report (à fournir avant de communiquer dessus).
- **Distribution** : empaquetage **standalone** — Python + moteur embarqués dans le `.app` (ne jamais dépendre d'un dossier protégé / de l'environnement de dev). Signature + notarisation Apple.
- **Mémoire** : SQLite par IA + embeddings locaux (model2vec multilingue).
- **Site** : landing premium + téléchargement (`.dmg`), waitlist (Netlify Forms).

---

## 7. Sécurité & confidentialité

- Données + modèles + mémoire : **uniquement sur la machine**.
- Mode agent (Her) : permissions explicites, granulaires, révocables ; jamais d'action destructrice sans confirmation.
- Aucune télémétrie par défaut.
- Tokens / secrets : jamais en clair, jamais transmis.

---

## 8. Priorisation (roadmap)

**P0 — Solidifier le cœur (en cours)**
- Qualité conversation (1.7B-Instruct), rappel mémoire fiable, CRUD + réglages, orbe interactive de base.

**P1 — Le produit qu'on installe**
- Empaquetage standalone signé + téléchargement depuis le site.
- Orbe interactive complète (tous les états §3).
- Onboarding « waouh ».

**P2 — Le différenciateur durable**
- Accélération ANE réelle (fluidité gros modèles, conso).
- Mémoire avancée (timeline, catégories, recherche).

**P3 — Mode « Her » (chantier dédié)**
- Voix (STT/TTS local) → agent mono-tâche → multi-tâches → orchestration paramétrable.

---

## 9. Axes R&D & inspirations avancées  *(au-delà du périmètre initial)*

Ces axes nourrissent P2/P3 et tirent Ember vers un produit unique. Chacun est inspiré
d'un travail public récent, et **réinterprété en 100% local sur Mac**.

### 9.A — Amélioration GUIDÉE, pas récursive  *(verdict d'analyse adverse — sans bullshit)*
> **Décision :** l'auto-amélioration *récursive* (le modèle se ré-entraîne sur ses propres
> sorties) = **NON.** Sur un petit modèle local sans signal de vérité externe, le **model
> collapse** est garanti et **silencieux** (la loss baisse, la qualité s'effondre dès 3-5
> itérations) + oubli catastrophique (<1B) + surchauffe Mac. L'AutoResearch de Karpathy
> marche car il a 4 conditions qu'Ember n'a PAS : objectif mesurable sur validation, GPU
> 40 Go+, bornes humaines, métriques reproductibles.

**Ce qu'on FAIT à la place (sûr, additif, prouvé) :**
- **Correction supervisée 1-itération** : l'utilisateur corrige (« en fait c'est X ») → on
  entraîne **un** adapter LoRA sur ces corrections (5-10 pas), **testé contre des
  "golden facts"** (régression = 0), **versionné, rollback 1 clic**. Jamais d'entraînement
  sur des sorties non validées.
- **Wiki personnel auto-maintenu** (cf. 9.B) : amélioration du *savoir* par inférence, pas
  des *poids* → zéro collapse.
- **In-context learning** : injecter faits/exemples pertinents dans le prompt (pas d'entraînement).
- **Skills (façon Hermes)** : extraire un *skill* réutilisable d'une tâche réussie —
  **avec validation** avant réutilisation (sinon on accumule de mauvais skills).

**Le seul "loop avec métrique" autorisé :** optimiser la *configuration* (retrieval, prompt,
réglages) contre un petit jeu de **golden facts** mesurable — un mini-autoresearch local
borné, qui ne touche **pas** aux poids du modèle.

### 9.B — Wiki personnel auto-maintenu  *(pattern « LLM Wiki » de Karpathy)*
Karpathy : ne pas utiliser le LLM comme moteur de recherche sur tes docs, mais comme un
**ingénieur de connaissances** qui compile, recoupe et **maintient un wiki vivant**.
Trois couches : `raw/` (sources brutes, immuables) → `wiki/` (pages générées par le modèle)
→ schéma. Plus simple et plus fiable que le RAG en dessous d'une certaine taille.
Pour Ember, c'est **l'évolution de la mémoire** :
- Tes données brutes (notes, mails, docs) vont dans `raw/`.
- Le **modèle local** en tire et maintient un **wiki personnel** (pages thématiques,
  recoupements, mises à jour) — inspectable et éditable, comme la mémoire de faits.
- Le rappel se fait sur ce wiki structuré → réponses fiables sans gros modèle.

### 9.C — Stratégie modèles pour Mac  *(leçon Kimi / MoE / MLX)*
- **Kimi K2.x = trop gros** pour un Mac grand public (MoE 1T, 350 Go+ ; réservé Mac Studio
  512 Go). On ne le vise PAS pour la cible « mamie ».
- Le vrai enseignement 2026 : les **MoE à faible budget actif** (3–17B activés par token sur
  un grand pool) tournent vite sur Mac car seuls les experts actifs sont chargés.
- **MLX** (framework Apple) bat llama.cpp de 30–40% sur M5 → backend d'inférence à évaluer
  à côté de l'ANE/Core ML.
- Stratégie Ember : petits modèles **Instruct distillés** (SmolLM2-Instruct, Gemma-4-E2B/E4B
  pour 8–16 Go), puis MoE-small-active quand pertinent, accélérés ANE/MLX.

### 9.D — Couche agent & orchestration  *(harness type Hermes, pour le mode Her)*
- Agent **persistant on-device** (pas du « un appel = une tâche »), mémoire procédurale,
  outils, permissions granulaires.
- **Orchestration** multi-agents paramétrable par l'utilisateur (qui fait quoi, dans quel
  ordre) — réglages exposés dans §4.C.
- Socle technique du mode « Her » (§4.E).

> Références : Hermes Agent (Nous Research), « LLM Wiki » d'A. Karpathy (X, avr. 2026),
> Kimi K2.x (Moonshot AI), MLX (Apple). À ré-explorer avant chaque phase concernée.

---

## 10. Critères de réussite (definition of done)

- Un inconnu télécharge Ember, l'installe en 1 clic, crée son IA, lui apprend ses données et discute — **sans aucune notion technique**.
- L'IA **restitue ses faits** de façon fiable après redémarrage.
- L'**orbe réagit visiblement** quand l'IA travaille — l'utilisateur *sent* la présence.
- L'expérience visuelle provoque un « waouh » au premier lancement.
- **Rien** n'a quitté la machine.
