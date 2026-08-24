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
| **Défaut** | Tous, avant tout search | Globale, au démarrage |
| **`--staged`** | Tous, après le premier restart (si nécessaire) | Globale, différée |
| **Per-node lazy** | Uniquement pour les nœuds touchés par le search | Par nœud, à la demande |

---

## Étape 0 — Comprendre `--staged` en profondeur

Avant d'implémenter quoi que ce soit, caractériser `--staged` sur les données existantes.

**Questions à répondre :**
- Quelle fraction des instances Stage 1 se termine sans jamais construire les supplémentaux ?
- Quel est le coût CPU du build des supplémentaux lors du boundary Stage 1→2 ?

**Code exact du boundary (vérifié 2026-06-29) :**

La logique staged vit dans `SequentialSolver::solve()` à `gss/homomorphism.cc:83–228` :
- Setup : lignes 116–120 (`staging` bool, `stage1_schedule` géométrique, `active_schedule`)
- Boucle restart : lignes 122–201
- Transition Stage 1→2 : lignes 181–190, case `SearchResult::Restart` :
  - `state.model->build_supplemental_graphs()` puis `tighten_domains_with_supplementals(domains)`
  - `active_schedule` bascule vers `params.restarts_schedule.get()` (le schedule utilisateur, pas nécessairement sans borne)
  - Les nogoods Stage 1 persistent dans `state.watches` à travers la transition

`build_supplemental_graphs()` : conditionnel à `homomorphism_model.cc:746`, défini ligne 752. Construit TOUS les graphes pour TOUS les sommets en une passe, met à jour degrés et `pattern_adjacencies_bits`.

`tighten_domains_with_supplementals()` : `homomorphism_model.cc:560` — re-filtre les domaines déjà initialisés (supplémentaux + NDS) sans ré-émettre les prunings g=0.

**Architecture pipeline (Phase 3 refactor) :** `solve_homomorphism_problem` orchestre via `SolveContext` + `SolveStep` (`homomorphism.cc:455+`). `MainSolveStep::run()` construit le modèle et lance `SequentialSolver` ou `ThreadedSolver`.

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

1. **default** : comportement actuel de Glasgow (tout au démarrage, pas de staged)
2. **`--staged`** : mode staged existant, budget défaut 100 backtracks
3. **`--no-supplementals`** : supplémentaux désactivés complètement (borne inférieure, pour quantifier la valeur des supplémentaux, pas pour la proposer comme solution)

**Métriques** : runtime (ms), search nodes, solved (bool), PAR-2 score par famille.

### Livrable

Tableau PAR-2 par famille × configuration. Ce tableau est la référence contre laquelle tout développement ultérieur sera mesuré. Sauvegarder dans `benchmark_results/baseline_YYYY-MM-DD.csv`.

---

## Étape 2 — Analyse de `--no-supplementals` sur le benchmark

Résultats (run 2026-06-29, 823 instances, timeout 60s) :

| Famille | n | solved default | solved nosup | avg_ms default | avg_ms nosup |
|---|---|---|---|---|---|
| LV | 285 | 285 | 274 | 62 | 316 |
| bio | 350 | 350 | 348 | 44 | 697 |
| images-CVIU11 | 59 | 59 | 59 | 188 | 60 |
| meshes-CVIU11 | 126 | 126 | 126 | 652 | 19 |
| scalefree | 3 | 3 | 3 | 193 | 16 |

**Conclusion :** Les supplémentaux sont critiques pour LV (11 instances non-résolues sans eux, 5× plus lent) et bio (2 non-résolues, 16× plus lent). Pour images, meshes, scalefree, les supplémentaux coûtent du temps sans apporter de gain en résolution — nosup est 3–34× plus rapide sur ces familles.

---

## Étape 3 — Analyse de `--staged` sur le benchmark

Résultats PAR-2 (seconds, 2×60 pour non-résolus) :

| Famille | default | staged | nosup |
|---|---|---|---|
| LV | 0.1 | 0.1 | 4.9 |
| bio | 0.0 | 0.0 | 1.1 |
| images-CVIU11 | 0.2 | **0.1** | 0.1 |
| meshes-CVIU11 | 0.6 | **0.0** | 0.0 |
| scalefree | 0.2 | **0.0** | 0.0 |
| ALL | 0.1 | **0.0** | 2.1 |

Métriques détaillées (avg_ms sur instances résolues) :

| Famille | default | staged | nosup |
|---|---|---|---|
| LV | 62 | 59 | 316 |
| bio | 44 | 41 | 697 |
| images-CVIU11 | 188 | 77 | 60 |
| meshes-CVIU11 | 652 | 21 | 19 |
| scalefree | 193 | 13 | 16 |

**Mécanisme pour meshes/scalefree :** 73/126 instances meshes et 3/3 scalefree ont `staged_nodes=0` (résolues en préprocessing de Stage 1 sans supplémentaux). Default construit les supplémentaux avant même le search → 30× plus lent. Staged évite ce coût.

**Mécanisme pour images :** Default résout toutes les instances avec 0 nœuds de search *mais* construit les supplémentaux en préprocess — coût 188ms. Staged (avg 40 nœuds) évite la construction pour les instances que Stage 1 résout sans supplémentaux → 2.4× plus rapide. nosup (60ms) est encore plus rapide car ne construit jamais.

**Hypothèse confirmée :** Staged domine default partout (jamais pire, parfois 2–30× mieux). Le gain vient des familles où les supplémentaux sont inutiles ou même contre-productifs (images, meshes, scalefree).

**Implication sur Variante 1 (lazy-on-first-branch) :** Cette variante construirait les supplémentaux *avant le premier branchement*, soit plus tôt que staged (qui attend un restart à 100 backtracks). Pour images et meshes — où staged tire son avantage précisément en évitant la construction sur les instances que Stage 1 résout sous le budget — Variante 1 serait *plus lente* que staged. **Variante 1 est dominée par `--staged` ; inutile de l'implémenter.**

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

### Contraintes architecturales (découvertes à la lecture du code)

Avant d'implémenter, noter :

1. **Slots pré-alloués** : `max_graphs` est fixé à la construction (`number_of_shape_graphs` dans le constructeur de `HomomorphismModel`). Les bitsets `pattern_graph_rows` et `target_graph_rows` ont déjà la taille `N * max_graphs`. Si `--no-supplementals`, `max_graphs=1` et aucun slot n'existe. Pour le lazy, on garde `--no-supplementals = false` et on alloue tous les slots mais on ne les remplit qu'à la demande.

2. **`HomomorphismSearcher` tient une `const HomomorphismModel &`** (`homomorphism_searcher.hh:78`). Pour appeler un build depuis le searcher, soit on rend les méthodes de build `mutable`, soit on passe un pointeur non-const séparément. Approche propre : `mutable` on the tracking bitset + builder methods sur le modèle, sans toucher au searcher.

3. **Les builders actuels sont globaux** : `build_exact_path_graphs` itère sur tous les sommets (`supplemental_graphs.cc`). Ils n'ont pas de variante par-sommet. Pour le lazy par-sommet, il faut ajouter des variantes qui ne remplissent que la ligne `p` (ou `t`) de chaque graphe supplémentaire. Mais le calcul d'une ligne nécessite quand même les adjacences de tous les autres sommets dans le graphe original → O(N) par sommet, O(N²) total, pas d'économie sur la complexité algorithmique. Le gain est sur la fraction des sommets effectivement branchés.

4. **`pattern_adjacencies_bits`** : tableau compressé des adjacences multi-graphes (`homomorphism_model.cc:738+`) doit aussi être mis à jour après chaque build partiel.

### Implémentation sans proof (recherche de performance pure)

**Variante 1 — "lazy-on-first-branch"** (la plus simple, différente de `--staged`) :
- Build all supplementals au moment où `restarting_search` est appelé la première fois à depth=0, *avant* le premier `find_branch_domain`. Pas de budget de restarts ni de schedule Stage 1.
- Différence avec `--staged` : pas de round de recherche préliminaire. On évite juste le build lors d'un UNSAT pur par preprocessing (domaine vide avant tout branchement).
- Implémentation : flag `--lazy-supplementals` dans `HomomorphismParams`, `HomomorphismModel` a un `mutable bool _supplementals_built = false` et une méthode `ensure_supplementals_built()` qui appelle `build_supplemental_graphs()` si nécessaire + `tighten_domains_with_supplementals`.

**Variante 2 — per-pattern-vertex lazy** (intéressante mais coûteuse à implémenter) :
- Ajouter à `HomomorphismModel` :
  - `mutable std::vector<bool> _pattern_supp_built` et `_target_supp_built` (initialisés à false)
  - `auto ensure_pattern_supplementals(unsigned p) -> void` : remplit uniquement la ligne `p` de chaque slot g=1..max_graphs-1, met à jour `patterns_degrees[g][p]` et les bits de `pattern_adjacencies_bits[p*N + *]`
  - Idem `ensure_target_supplementals(unsigned t)` pour le côté target
- Dans `restarting_search`, après `find_branch_domain` retourne le domaine pour p :
  - `model.ensure_pattern_supplementals(branch_domain->v)`
  - Pour chaque t dans le domaine : `model.ensure_target_supplementals(t)` (potentiellement coûteux si domaine large)
- Les builders existants devront être refactorisés pour accepter un paramètre `int only_vertex = -1` (-1 = tous).

**Recommandation** : commencer par la Variante 1 (rapide à implémenter, facile à benchmarker), puis décider si la Variante 2 vaut le coût selon les résultats.


---

## Étape 5 — Implémentation de la Variante 2 (per-vertex lazy)

### Implémentation v1 — bogues identifiés (2026-06-29)

Première implémentation sous `--lazy-supplementals` : correcte sur les résultats (823/823 instances, même status que default), mais deux erreurs structurelles :

**Bug 1 — Target side non-lazy.** `ensure_all_target_supplementals()` construit TOUS les rows target en une passe (même coût que le mode défaut). La bonne implémentation est `ensure_target_supplementals(t)` appelée par valeur dans la boucle du domaine de p : ne construire que les rows des t effectivement présents dans dom(p).

**Bug 2 — NDS supprimé silencieusement.** `supplemental_degree_ok` ne vérifie que le degré. `tighten_domains_with_supplementals` (la référence dans staged) vérifie aussi NDS. NDS requiert `pattern_degree(g, q)` pour q ∈ N_g(p) et `target_degree(g, u)` pour u ∈ N_g(t). Si les supplémentaux de q ou u ne sont pas encore construits, leurs degrés sont 0 → pruning incorrect (faux-positifs ou faux-négatifs). Correct fix : ne pas appliquer NDS dans le mode lazy pour l'instant, ou construire aussi les supplémentaux des voisins g=0 de p avant le check NDS. À faire en Variante 2 v2.

Résultats avec ces bugs (benchmark lazy_2026-06-29.csv) :

| Famille | default_t | staged_t | lazy_t | default_n | staged_n | lazy_n |
|---|---|---|---|---|---|---|
| LV | 0.06 | 0.05 | 1.97 | 117 | 159 | 31446 |
| bio | 0.03 | 0.03 | 1.79 | 1973 | 2099 | 7066 |
| images-CVIU11 | 0.20 | 0.08 | 0.18 | 0 | 40 | 5 |
| meshes-CVIU11 | 0.62 | 0.02 | 0.18 | 1 | 3 | 1 |

Lazy fait **265× plus de nœuds** sur LV que default (31446 vs 117) : les domaines restent larges car seul p est filtré, le reste du search part avec des domaines coarses (g=0 uniquement depuis initialise_domains stage1=true).

### Implémentation v2 — fix per-target lazy

**Changements :**
- `Imp::lazy_target_built` : `bool` → `vector<bool>` de taille target_size
- Supprimer `ensure_all_target_supplementals()`
- Ajouter `ensure_target_supplementals(unsigned t)` : builders per-vertex avec `pattern=false`, strip/restore target loops, met à jour `targets_degrees[g][t]`
- Searcher : pour chaque t dans dom(p), appeler `ensure_target_supplementals(t)` avant `supplemental_degree_ok(p, t)`

**Limitation NDS :** NDS reste désactivé. Pour l'activer correctement, il faudrait aussi construire les supplémentaux des voisins g=0 de p (pour `pattern_degree(g, q)`) et les voisins dans les graphes supplémentaux de t (pour `target_degree(g, u)`). Coût supplémentaire potentiellement élevé sur les graphes denses. À évaluer dans une v3 si les nœuds restent trop nombreux.

**Prochaine action :** Benchmark post-fix pour mesurer l'impact sur les nœuds.

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

- Glasgow staged mode : `gss/homomorphism.cc:83–228` (`SequentialSolver::solve()`), transition à la ligne 181–190, params à `gss/homomorphism.hh:99,105`
- Build supplemental graphs (conditionnel) : `gss/innards/homomorphism_model.cc:746` ; fonction : ligne 752
- Tighten domains (post-staged) : `gss/innards/homomorphism_model.cc:560`
- Traits (no_supplementals) : `gss/innards/homomorphism_traits.cc:15–33`
- Searcher (find_branch_domain) : `gss/innards/homomorphism_searcher.cc:350`, appelé à la ligne 105
- Supplemental builders : `gss/innards/supplemental_graphs.cc` (fonctions globales, pas per-vertex)
- Supplémentaux comme innovation clé : McCreesh, Prosser, Trimble — papiers newSIP (à citer précisément)
