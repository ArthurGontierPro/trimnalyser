# Plan : génération lazy des supplémentaux dans Glasgow

## Contexte et motivation

Les données du 6-29-fullrun montrent que les contraintes `gNadj` (supplémentaux) et `pathgN` (path-consistency) ont des taux de survie au trimming de 0.5–5%, mais représentent jusqu'à 50% du proof complet pour images-CVIU11 (pathg1 seul = 32%) et 13% pour bio. Glasgow les génère actuellement toutes en préprocess, pour tous les nœuds du pattern, avant toute search.

**Important — les supplémentaux ne sont pas une feature accessoire.** Ils constituent l'innovation centrale de Glasgow par rapport à la littérature de SIP (cf. papiers McCreesh, Prosser, Trimble). Les désactiver statiquement (ablation) dégraderait le solveur de façon significative sur les familles qui en dépendent (images, bio). L'objectif est donc de les générer plus intelligemment, pas de les supprimer.

**Le mode `--staged` existe déjà** dans Glasgow et implémente une version coarse de cette idée :
- Stage 1 : preprocessing sans supplémentaux + search bornée à `staged_first_round_backtracks` (défaut 100)
- Si Stage 1 se conclut → terminé, aucun supplémentaux construit
- Si Stage 1 atteint son budget → build **tous** les supplémentaux au boundary level-0 (valide pour la preuve car on est remonté à la racine), re-filtre, Stage 2 sans borne

Ce plan vise à comprendre les gains de `--staged`, puis à explorer si une granularité plus fine (per-node lazy) apporte un gain supplémentaire.

---

## Paysage des stratégies

| Mode | Supplémentaux construits | Granularité |
|---|---|---|
| **Eager (défaut)** | Tous, avant tout search | Globale, au démarrage |
| **`--staged`** | Tous, après le premier restart (si nécessaire) | Globale, différée |
| **Per-node lazy** | Uniquement pour les nœuds touchés par le search | Par nœud, à la demande |

---

## Étape 0 — Comprendre `--staged` en profondeur

Avant d'implémenter quoi que ce soit, caractériser `--staged` sur les données existantes.

**Questions à répondre :**
- Quelle fraction des instances Stage 1 se termine sans jamais construire les supplémentaux ?
- Quel est le coût CPU du build des supplémentaux lors du boundary Stage 1→2 ?

**Action :** Lire `homomorphism.cc:181–189` + `homomorphism_model.cc:746` pour confirmer le comportement exact du boundary. Vérifier les flags actuels dans `trimnalyser/trimnalyser` (wrapper bash).

---

## Étape 1 — Benchmark de référence (baseline)

Construire la suite de benchmark qui servira de point de comparaison pour toutes les modifications suivantes.

### Instances à utiliser

Sous-ensemble représentatif du 6-29-fullrun, stratifié par famille et difficulté :

| Famille | Critère de sélection | Nombre cible |
|---|---|---|
| LV | Instances avec search nodes > 0 (exclure 0-nœuds) | 200 |
| bio | Mix : 50% avec g1adj cone > 0, 50% sans | 400 |
| images-CVIU11 | Toutes instances avec proof complet disponible | 300 |
| meshes-CVIU11 | Échantillon aléatoire (pas de supplémentaux attendus) | 100 |
| phase | Toutes instances disponibles | 50 |

Script : `scripts/benchmark_suite.jl` — génère la liste d'instances + lance les runs en parallèle avec timeout fixe. Reprendre la structure de `scripts/oracle_replay.jl`.

Pour une liste fixe et representatife d'instances utiliser celles listees dans `6-29-fullrun/instances.txt`

### Configurations à mesurer

Pour chaque instance, mesurer les 3 configurations suivantes (baseline) :

1. **default** : comportement actuel de Glasgow (eager, pas de staged)
2. **`--staged`** : mode staged existant, budget défaut 100 backtracks
3. **`--no-supplementals`** : supplémentaux désactivés complètement (borne inférieure, pour quantifier la valeur des supplémentaux, pas pour la proposer comme solution)

**Métriques** : runtime (ms), search nodes, solved (bool), PAR-2 score par famille.

### Livrable

Tableau PAR-2 par famille × configuration. Ce tableau est la référence contre laquelle tout développement ultérieur sera mesuré. Sauvegarder dans `benchmark_results/baseline_YYYY-MM-DD.csv`.

---

## Étape 2 — Analyse de `--no-supplementals` sur le benchmark


---

## Étape 3 — Analyse de `--staged` sur le benchmark

Avec les résultats de l'étape 1, analyser finement `--staged` :

- Pour les instances où Stage 1 se conclut sans supplémentaux : gain de temps vs eager ?
- Pour les instances où Stage 1 échoue (boundary atteint) : overhead du build delayed vs eager ?
- Taux de transition Stage 1→2 par famille (fraction des instances qui atteignent le boundary)

**Hypothèse à tester :** `--staged` devrait dominer `default` sur les instances résolues par preprocessing pur (Stage 1 se conclut en UNSAT via domaine vide), et être neutre ou légèrement négatif sur les instances qui nécessitent search + supplémentaux.

---

## Étape 4 — Conception du per-node lazy (si étapes 2–3 le justifient)

Si le profilage confirme que le build des supplémentaux est coûteux ET que `--staged` ne capture pas tout le gain potentiel, concevoir le per-node lazy.

### Définition de "nœud touché"

Candidats (par ordre de coarseness décroissante) :

1. **Au restart** (= `--staged` existant) — trop coarse
2. **Lors du branchement** sur le nœud pattern p : générer les supplémentaux de p avant d'instancier, idem pour le target t
3. **Lors de la première réduction de domaine**

Le candidat le plus naturel est (2) : générer les supplémentaux de p et t immédiatement avant que le search branche sur p=t. S'inspirer du code pour l'option --staged.

### Contrainte proof

Le mode staged actuel construit les supplémentaux au boundary level-0 précisément parce que la dérivation VeriPB est plus simple à la racine. Pour le per-node lazy au moment du branchement (level > 0) determiner la meilleur approche, attention il faut bien comprendre ce que l'on met dans la preuve.

### Implémentation sans proof (recherche de performance pure)

Si on vise d'abord la performance sans proof logging :
- Ajouter un flag `--lazy-supplementals` dans `HomomorphismParams`
- Dans `homomorphism_searcher.cc`, avant `find_branch_domain()`, vérifier si le nœud sélectionné p a ses supplémentaux construits ; si non, appeler `model.build_supplemental_for_node(p)` et re-propager
- `build_supplemental_for_node(p)` : factoriser le code existant de `build_supplemental_graphs()` pour opérer sur un seul pattern vertex
se poser la question des target vertex aussi.


---

## Étape 5 — Benchmark final et décision

Comparer sur le même benchmark (étape 1) :

| Configuration | Description |
|---|---|
| default | eager, no staged |
| staged-100 | `--staged`, budget 100 (défaut) |
| staged-calibré | `--staged` avec budget par famille (étape 5) |
| lazy-no-proof | per-node lazy sans proof (si implémenté, étape 4) |

Décision : adopter la configuration avec le meilleur PAR-2 global, dans l'ordre de préférence :
1. staged-calibré si gain ≥ 5% PAR-2 sans régression
2. lazy-no-proof si staged-calibré insuffisant et gain mesuré > coût d'implémentation
3. statu quo si aucun gain significatif

---

## Plan de fichiers et branches

| Fichier | Rôle |
|---|---|
| `scripts/benchmark_suite.jl` | Génération de la suite + runner parallèle |
| `benchmark_results/baseline_YYYY-MM-DD.csv` | Référence PAR-2 par famille × config |
| Glasgow branch `lazy-supplementals` | Instrumentation timing + optionnel : lazy flag |
| `docs/lazy-supplementals-plan.md` | Ce document |

---

## Dépendances avec la roadmap principale

- Ce plan est **parallèle à M3.5.4** (pas de dépendance directe)
- Ses résultats alimentent **M4** : le réglage du budget staged par famille est un des "heuristic dimensions" de M4
- Si per-node lazy est adopté → M6 (intégration) inclut ce flag dans la sélection automatique

---

## Références

- Glasgow staged mode : `gss/homomorphism.cc:111–189`, `gss/homomorphism.hh:94–105`
- Build supplemental graphs : `gss/innards/homomorphism_model.cc:746`
- Supplémentaux comme innovation clé : McCreesh, Prosser, Trimble — papiers newSIP (à citer précisément)
