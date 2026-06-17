# Ember — Cahier des charges

*Document de référence produit (source de vérité unique). Moteur open-source : ANEForge. Application grand public : Ember.*
*Version 0.2 — 2026-06-16.*

---

## 1. Vision

> **Transformer le Mac de n'importe qui en une IA personnelle qui apprend de ses propres données, vit entièrement en local, et finit par agir sur tout l'ordinateur — d'une simplicité enfantine, dans la philosophie Apple. Internationale par conception : toutes les langues majeures, scalable.**

Ember n'est pas « encore un chatbot local ». C'est **une présence** : une IA qui vous connaît, que vous contrôlez, qui ne vous trahit jamais (rien ne quitte la machine), et dont l'**expérience visuelle est aussi forte que la technologie**.

Ambition : devenir *le* nom de l'IA personnelle locale sur Mac, **mondialement** — au point d'être stratégique pour Apple.

---

## 2. Principes directeurs (non négociables)

1. **100% local.** Aucune donnée ne quitte la machine. Pas de cloud, pas de compte obligatoire, pas de traçage.
2. **Le visuel vaut la fonctionnalité.** Chaque écran doit être au niveau d'une page produit Apple. Une fonctionnalité sans une forme superbe est considérée incomplète.
3. **Simplicité « mamie ».** Zéro jargon visible. Tout ce qui est technique est caché ou traduit en langage humain.
4. **Honnêteté.** On n'affiche jamais une capacité qu'on n'a pas (ex : « Neural Engine activé », pas « entraîné sur l'ANE » tant que non prouvé).
5. **L'utilisateur garde la main.** Tout ce que l'IA sait est inspectable, modifiable, supprimable.
6. **Open-core.** Le moteur (ANEForge) est open source ; l'app et l'expérience sont le produit.
7. **International par conception.** Ember fonctionne dans **toutes les langues majeures** dès le départ — modèle multilingue, mémoire multilingue, interface localisée. Aucune logique ne doit être verrouillée à une langue (pas de regex « FR/EN seulement »).

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
- 100% local, sur Apple Silicon ; inférence MLX (Neural Engine en complément).
- **Ingestion des données (à concevoir)** : glisser un fichier/dossier (.txt/.md/.pdf), connecteurs locaux en lecture seule (Apple Notes, Mail, Obsidian). UX cœur du « apprends de moi ».

### 4.B — CRUD & gestion des IA  *(état : fait)*
- Créer / lister / **supprimer** une IA (confirmation, irréversible).
- Renommer (à ajouter), dupliquer (P2).

### 4.C — Paramétrage  *(état : base faite, à étendre)*
- **Choix du modèle** (léger / équilibré / puissant).
- **Persona** : ton, style — et **langue** (auto-détectée par défaut).
- **Longueur des réponses**, température (P1).
- **Réglages d'agent & d'orchestration** (P2, mode Her) : qui agit, dans quel ordre, avec quelles permissions.

### 4.D — Mémoire personnelle  *(état : éditable + sémantique faite ; extraction à internationaliser)*
- Faits stockés dans une mémoire **inspectable / éditable / supprimable** (`memory / remember / forget`).
- **Rappel fiable** : mots-clés + **sémantique multilingue** (« métier » trouve « boulanger »). ✅ multilingue.
- 🔴 **Extraction des faits à passer en "par le modèle"** : l'actuelle est en **regex FR+EN** (ne scale pas aux autres langues). Faire extraire les faits par le LLM (marche dans toutes les langues) — viole sinon le principe §2.7.
- À venir : timeline des faits, sources, catégories, recherche.

### 4.E — Mode « Her » : plein-ordinateur  *(étoile polaire, chantier majeur dédié)*
- **Voix** : entrée (STT local) + sortie (TTS local), **multilingues** — conversation mains-libres.
- **Agent** : l'IA agit sur l'ordinateur (fichiers, apps, recherche, automatisations) sur **plusieurs tâches**.
- **Orchestration** : plusieurs agents/spécialistes coordonnés, paramétrables par l'utilisateur.
- **Permissions** : explicites, granulaires, révocables (agir sur l'ordi est sensible).
- **Toujours en local**, basse conso grâce à l'ANE.

### 4.F — Qualité & moteur d'inférence  *(P0 — prouvé)*
- **MLX (Apple) = moteur d'inférence principal.** PROUVÉ sur M5 : Qwen2.5-1.5B-Instruct-4bit → français fluide, **ancre les faits injectés**, **56 tok/s à chaud**. Passage « démo → produit ». Le moteur Rust/CoreML reste pour le training perso et l'ANE.
- **Modèles multilingues par défaut** : Qwen2.5-1.5B/3B-Instruct (fort multilingue) — cohérent avec §2.7. SmolLM2-Instruct pour l'entrée de gamme (8 Go).
- **Persona adaptatif à la langue** de l'utilisateur (pas de défaut français codé en dur).
- Format **ChatML / chat template** du modèle (fait).
- **ANE = efficacité/long terme**, PAS le chemin de la fluidité court terme (re-priorisé).

---

## 5. Périmètre visuel  *(au même rang que le fonctionnel)*

1. **Identité Ember cohérente** entre le site et l'app : thème sombre chaud, braise, typographie éditoriale.
2. **Orbe interactive** (cf. §3) — l'exigence visuelle n°1.
3. **App au niveau page produit Apple** : pas un « dossier ». Profondeur, lueurs, micro-animations, transitions fluides.
4. **Chat vivant** : bulles soignées, réponse token-par-token, l'orbe qui réagit pendant la génération.
5. **Onboarding magique** : le premier lancement donne le « waouh ».
6. **Cohérence multi-tailles** : fenêtre redimensionnable, sans débordement.
7. **Icône = la braise** (fait), Dock + fenêtre.
8. **Interface localisée (i18n)** : tous les textes UI traduisibles, langue suivant le système (cohérent §2.7).

---

## 6. Technique & architecture

- **Moteur** : **MLX (inférence principale)** + Rust (`ane-core` : training perso, LoRA, BLAS) + ObjC (`ane-sys` : ANE) + Python (orchestration, HF) + Swift (app).
- **Daemon persistant** (`ember_daemon.py`, localhost) tient le modèle MLX + mémoire en RAM → chat instantané ; l'app est un client HTTP.
- **Inférence ANE** : Core ML public (computeUnits=All). Dispatch op-par-op = Core ML Performance Report. Secondaire vs MLX au court terme.
- **Distribution** : empaquetage **standalone** — Python + moteur embarqués dans le `.app` (jamais de dépendance à un dossier protégé / l'environnement de dev).
- **🔴 Signature + notarisation Apple** : requiert un **compte Apple Developer (99 $/an)**. Sans ça, Gatekeeper bloque chez l'inconnu. Gate à décider tôt.
- **Harnais d'évaluation (golden facts)** : jeu de référence par IA, mesure « meilleur/pire » à chaque changement. Prérequis de §9.A.
- **i18n** : système de chaînes localisées (app Swift + persona/prompts moteur).
- **Licences modèles** : SmolLM2/Qwen (Apache, OK), Llama (gated/licence). Histoire de licence propre pour distribuer.
- **Mises à jour** : Sparkle (updates Mac signées).
- **Mémoire** : SQLite par IA + embeddings locaux (model2vec multilingue).
- **Site** : landing premium + téléchargement (`.dmg`), waitlist (Netlify Forms).

---

## 7. Sécurité & confidentialité

- Données + modèles + mémoire : **uniquement sur la machine**.
- Mode agent (Her) : permissions explicites, granulaires, révocables ; jamais d'action destructrice sans confirmation.
- Aucune télémétrie par défaut.
- Tokens / secrets : jamais en clair, jamais transmis.
- **Preuve de confidentialité = moat** : viser un entitlement « pas de réseau » sur le cœur (ou moniteur réseau zéro-sortie). Le « 100% local » prouvé = argument de confiance + pitch.

---

## 8. Priorisation (roadmap)

**P0 — Le produit utilisable (en cours, MLX prouvé)**
- Backend MLX + Qwen2.5-1.5B-Instruct (conversation fluide — prouvé : 56 tok/s sur M5).
- Rappel mémoire fiable (mémoire-first + sémantique), CRUD + réglages, orbe interactive de base.

**Definition of Done P0 (mesurable) :**
1. Sur 10 prompts variés (FR + au moins 1 autre langue) → **≥ 8** réponses fluides/justes.
2. **5/5** faits perso restitués après fermer→rouvrir.
3. **≥ 20 tok/s à chaud** (mesuré : 56 → OK).
4. Boucle app créer→apprendre→discuter sans erreur.
5. Un non-technique l'utilise 5 min → « ça marche, et ça me connaît ».

**Critères d'ARRÊT (kill-criteria) :**
- Meilleur modèle à ≥ 20 tok/s ne tient pas 3 tours cohérents → 100% local trop tôt → pivot.
- Rappel mémoire < 4/5 fiable → réparer le cœur avant tout.
- Standalone casse l'accès fichiers/agent → repenser la distribution.

**P1 — Le produit qu'on installe**
- Empaquetage standalone signé + téléchargement depuis le site.
- Orbe interactive complète (tous les états §3).
- **Extraction de faits par le modèle (multilingue)** + **i18n de l'UI** (principe §2.7).
- Onboarding « waouh ».

**P2 — Le différenciateur durable**
- Accélération ANE réelle (fluidité gros modèles, conso).
- Mémoire avancée (timeline, catégories, recherche) ; wiki personnel (§9.B).

**P3 — Mode « Her » (chantier dédié)**
- Voix multilingue (STT/TTS local) → agent mono-tâche → multi-tâches → orchestration paramétrable.

---

## 9. Axes R&D & inspirations avancées  *(au-delà du périmètre initial)*

Ces axes nourrissent P2/P3. Chacun est inspiré d'un travail public récent, **réinterprété 100% local sur Mac**.

### 9.A — Amélioration GUIDÉE, pas récursive  *(verdict d'analyse adverse — sans bullshit)*
> **Décision :** l'auto-amélioration *récursive* (le modèle se ré-entraîne sur ses propres sorties) = **NON.** Sur un petit modèle local sans signal de vérité externe, le **model collapse** est garanti et **silencieux** (loss qui baisse, qualité qui s'effondre dès 3-5 itérations) + oubli catastrophique (<1B) + surchauffe Mac. L'AutoResearch de Karpathy marche car il a 4 conditions qu'Ember n'a PAS : objectif mesurable sur validation, GPU 40 Go+, bornes humaines, métriques reproductibles.

**Ce qu'on FAIT à la place (sûr, additif, prouvé) :**
- **Correction supervisée 1-itération** : l'utilisateur corrige → un adapter LoRA (5-10 pas), **testé contre des golden facts** (régression = 0), **versionné, rollback 1 clic**. Jamais d'entraînement sur des sorties non validées.
- **Wiki personnel auto-maintenu** (cf. 9.B) : amélioration du *savoir* par inférence, pas des *poids* → zéro collapse.
- **In-context learning** : injecter faits/exemples pertinents dans le prompt.
- **Skills (façon Hermes)** : extraire un *skill* réutilisable d'une tâche réussie — **avec validation** avant réutilisation.

**Seul "loop avec métrique" autorisé :** optimiser la *configuration* (retrieval, prompt, réglages) contre des **golden facts** — mini-autoresearch local borné, qui ne touche **pas** aux poids.

### 9.B — Wiki personnel auto-maintenu  *(pattern « LLM Wiki » de Karpathy)*
Le LLM n'est pas un moteur de recherche sur tes docs, mais un **ingénieur de connaissances** qui compile, recoupe, **maintient un wiki vivant**. Couches : `raw/` (sources immuables) → `wiki/` (pages générées) → schéma. Plus fiable que le RAG sous une certaine taille. Pour Ember = **l'évolution de la mémoire** : tes données brutes → wiki personnel multilingue maintenu par le modèle, inspectable/éditable.

### 9.C — Stratégie modèles pour Mac  *(leçon Kimi / MoE / MLX)*
- **Kimi K2.x = trop gros** pour le grand public (MoE 1T, 350 Go+). Pas la cible.
- Enseignement 2026 : **MoE à faible budget actif** (3–17B activés) tournent vite sur Mac.
- **MLX** bat llama.cpp de 30–40% sur M5 → moteur principal.
- Stratégie : petits **Instruct multilingues distillés** (Qwen, Gemma-4-E2B/E4B), puis MoE-small-active.

### 9.D — Couche agent & orchestration  *(harness type Hermes, mode Her)*
- Agent **persistant on-device**, mémoire procédurale, outils, permissions granulaires.
- **Orchestration** multi-agents paramétrable (§4.C). Socle du mode « Her » (§4.E).

> Références : Hermes Agent (Nous Research), « LLM Wiki » d'A. Karpathy (X, avr. 2026), Kimi K2.x (Moonshot AI), MLX (Apple). À ré-explorer avant chaque phase.

---

## 10. Modèle économique

**Freemium local-first.**
- **Gratuit** : l'app + le moteur, 100% local → moat privacy + acquisition virale (mondiale).
- **Payant (~9–12 €/mois)** : synchro **chiffrée** du modèle/mémoire entre appareils · bibliothèque de modèles optimisés en 1 clic · connecteurs locaux · offre pro.
- **Économie** : local = **zéro coût serveur = forte marge** ; la valeur payante justifie l'abo **sans trahir le local**.
- **Distribution** : `.dmg` direct d'abord (liberté agent/fichiers), Mac App Store ensuite (version lite).
- **Principe** : on ne construit **pas pour un rachat Apple** — sortie possible, jamais le plan.

---

## 11. Critères de réussite (definition of done)

- Un inconnu, **dans sa langue**, télécharge Ember, l'installe en 1 clic, crée son IA, lui apprend ses données et discute — **sans aucune notion technique**.
- L'IA **restitue ses faits** de façon fiable après redémarrage.
- L'**orbe réagit visiblement** quand l'IA travaille — l'utilisateur *sent* la présence.
- L'expérience visuelle provoque un « waouh » au premier lancement.
- **Rien** n'a quitté la machine.
