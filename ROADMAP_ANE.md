# Roadmap — Intégration ANE complète (forward hybride)

Objectif : faire tourner le **forward du transformer sur l'ANE** (les gros matmuls)
avec la colle légère sur CPU, pour débloquer l'apprentissage **continu en arrière-plan,
froid et silencieux** — le truc inimitable de la Strate 2.

Architecture cible (hybride, comme la SOTA maderix) :
```
ANE  : projections q/k/v/o, FFN (gate/up/down)  ← 99% des FLOPs, gros matmuls
CPU  : RoPE, masquage causal, RMSNorm, softmax   ← colle légère, l'ANE gère mal
```

## Acquis (déjà prouvé, committé)
- ✅ Exécution ANE vérifiée sur M5 (graphe jouet)
- ✅ Vrai matmul sur ANE = CPU (err FP16 0.0012)
- ✅ Pont Python→ANE→Python (`ane_kernel.LinearKernel`)

---

## Étape A — Un layer d'attention complet sur ANE
**But** : compiler q/k/v/o + l'attention d'UNE couche en MLProgram(s), exécuter sur
ANE, valider contre le forward Rust.
**Livrable** : `ane_layer.py` (compile + run d'une couche attention).
**Test de validation** : sortie ANE d'une couche vs sortie Rust CPU, err < 1e-2 sur
un vrai poids SmolLM2. ✅/❌ binaire.

## Étape B — Le FFN sur ANE
**But** : ajouter gate/up/down + SiLU. SiLU sur ANE si supporté, sinon CPU.
**Livrable** : `ane_layer.py` gère la couche FFN.
**Test** : couche FFN ANE vs Rust, err < 1e-2.

## Étape C — Forward complet d'un modèle sur ANE
**But** : chaîner toutes les couches (embeddings CPU → N couches hybrides → classifier
ANE). Gérer la limite ~119 compiles (compiler chaque kernel UNE fois, réutiliser).
**Livrable** : `ANEBackend` branché dans le moteur, sélectionnable par `backend="ane"`.
**Test** : `generate()` via ANE produit le MÊME texte que le CPU sur SmolLM2-135M.

## Étape D — Mesure du gain réel (la raison d'être)
**But** : mesurer ce qui compte vraiment — énergie et chaleur, pas que la vitesse.
**Livrable** : bench `powermetrics` : Watts ANE vs CPU, température, tokens/s.
**Test** : chiffres réels dans un rapport. Si l'ANE consomme nettement moins → la
thèse "apprentissage continu en arrière-plan" est validée.

## Étape E — Apprentissage en arrière-plan (le produit magique)
**But** : l'app lance l'entraînement ANE en tâche de fond, basse priorité (QoS), quand
le Mac est au repos. "Ton IA apprend de toi pendant que tu dors."
**Livrable** : daemon background dans l'app macOS + réglage QoS ANE.
**Test** : entraînement tourne en fond sans bloquer la machine ni chauffer.

---

## Gates de décision (on ne fonce pas aveugle)
- Après **A** : si une couche d'attention ne valide pas proprement sur ANE, on
  re-scope (peut-être seulement les projections + FFN sur ANE, attention 100% CPU).
- Après **D** : si le gain énergétique n'est PAS significatif, on s'arrête là —
  l'ANE reste un argument marketing prouvé, pas le chemin de prod. Honnêteté d'abord.

## Ce qui vient APRÈS l'ANE (rappel, ordre validé)
1. ANE [ce plan]
2. App distribuable (.app signé + Python embarqué)
3. README honnête + lancement
